################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2018 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader$
# 
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package Apache::WeBWorK;

=head1 NAME

Apache::WeBWorK - mod_perl handler for WeBWorK 2.

=head1 CONFIGURATION

This module should be installed as a Handler for the location selected for
WeBWorK on your webserver. Refer to the file F<conf/webwork.apache-config> for
details.

=cut

use strict;
use warnings;
use Apache2::Const qw(:common);
use HTML::Entities;
use HTML::Scrubber;
use Date::Format;
use WeBWorK;
use Encode;
use utf8;
use JSON::MaybeXS;
use UUID::Tiny  ':std';

use constant MP2 => ( exists $ENV{MOD_PERL_API_VERSION} and $ENV{MOD_PERL_API_VERSION} >= 2 );

# Should the minimal (more secure) HTML error output be used?
use constant MIN_HTML_ERRORS => ( exists $ENV{"MIN_HTML_ERRORS"} and $ENV{"MIN_HTML_ERRORS"} );

# Should Apache logs get JSON formatted record?
use constant JSON_ERROR_LOG => ( exists $ENV{"JSON_ERROR_LOG"} and $ENV{"JSON_ERROR_LOG"} );

# load correct modules
BEGIN {
	if (MP2) {
		require Apache2::Log;
		Apache2::Log->import;
	} else {
		require Apache::Log;
		Apache::Log->import;
	}
}

################################################################################

=head1 APACHE REQUEST HANDLER

=over

=item handler($r)

=cut

sub handler($) {
	my ($r) = @_;
	my $log = $r->log;
	my $uri = $r->uri;


	# We set the bimode for print to utf8 because some language options
	# use utf8 characters
	binmode(STDOUT, "encoding(UTF-8)");
	# the warning handler accumulates warnings in $r->notes("warnings") for
	# later cumulative reporting
	my $warning_handler;
	if (MP2) {
		$warning_handler = sub {
			my ($warning) = @_;
			chomp $warning;
			my $warnings = $r->notes->get("warnings");
			$warnings = Encode::decode_utf8($warnings);
			$warnings .= "$warning\n";
			#my $backtrace = join("\n",backtrace());
			#$warnings .= "$backtrace\n\n";
			$warnings = Encode::encode_utf8($warnings);
			$r->notes->set(warnings => $warnings);
			
			$log->warn("[$uri] $warning");
		};
	} else {
		$warning_handler = sub {
			my ($warning) = @_;
			chomp $warning;
			
			my $warnings = $r->notes("warnings");
			$warnings .= "$warning\n";
			#my $backtrace = join("\n",backtrace());
			#$warnings .= "$backtrace\n\n";
			$r->notes("warnings" => $warnings);
			
			$log->warn("[$uri] $warning");
		};
		
		# the exception handler generates a backtrace when catching an exception
		my @backtrace;
		my $exception_handler = sub {
			@backtrace = backtrace();
			die @_;
		};
	}
	
	# the exception handler generates a backtrace when catching an exception
	my @backtrace;
	my $exception_handler = sub {
		@backtrace = backtrace();
		die @_;
	};
	
	my $result = do {
		local $SIG{__WARN__} = $warning_handler;
		local $SIG{__DIE__} = $exception_handler;
		
		eval { WeBWorK::dispatch($r) };
	};
	
	if ($@) {
		my $exception = $@;
		
		my $warnings = MP2 ? $r->notes->get("warnings") : $r->notes("warnings");
		my $htmlMessage;
		my $uuid = create_uuid_as_string(UUID_SHA1, UUID_NS_URL, $r->uri )
		  . "::" . create_uuid_as_string(UUID_TIME);
		my $time = time2str("%a %b %d %H:%M:%S %Y", time);

		if ( MIN_HTML_ERRORS ) {
			$htmlMessage = htmlMinMessage($r, $exception, $uuid, $time);
		} else {
			$htmlMessage = htmlMessage($r, $warnings, $exception, $uuid, $time, @backtrace);
		}
		unless ($r->bytes_sent) {
			$r->content_type("text/html");
			$r->send_http_header unless MP2; # not needed for Apache2
			$htmlMessage = "<html lang=\"en-US\"><head><title>WeBWorK error</title></head><body>$htmlMessage</body></html>";
		}
		
		# log the error to the apache error log
		my $logMessage;
		if ( JSON_ERROR_LOG ) {
			$logMessage = jsonMessage($r, $warnings, $exception, $uuid, $time, @backtrace);
		} else {
			$logMessage = textMessage($r, $warnings, $exception, $uuid, $time, @backtrace);
		}
		$log->error($logMessage);

		$r->custom_response(FORBIDDEN,$htmlMessage);

		$result = FORBIDDEN;
	}
	
	return $result;
}

=back

=cut

################################################################################

=head1 ERROR HANDLING ROUTINES

=over

=item backtrace()

Produce a stack-frame traceback for the calls up through the ones in
Apache::WeBWorK.

=cut

sub backtrace {
	my $frame = 2;
	my @trace;
	
	while (my ($pkg, $file, $line, $subname) = caller($frame++)) {
		last if $pkg eq "Apache::WeBWorK";
		push @trace, "in $subname called at line $line of $file";
	}
	
	return @trace;
}

=back

=cut

################################################################################

=head1 ERROR OUTPUT FUNCTIONS

=over

=item htmlMessage($r, $warnings, $exception, $uuid, $time, @backtrace)

Format a message for HTML output reporting an exception, backtrace, and any
associated warnings.

=cut

sub htmlMessage($$$@) {
	my ($r, $warnings, $exception, $uuid, $time, @backtrace) = @_;

	# Warnings have html and look better scrubbed. 

	my $scrubber = HTML::Scrubber->new(
	    default => 1,
	    script => 0,
	    comment => 0
	    );
	$scrubber->default(
	    undef,
	    {
		'*' => 1,
	    }
	    );

	$warnings = $scrubber->scrub($warnings);
	$exception = $scrubber->scrub($exception);

	my @warnings = defined $warnings ? split m|<br />|, $warnings : ();  #fragile
	$warnings = htmlWarningsList(@warnings);
	my $backtrace = htmlBacktrace(@backtrace);

	# $ENV{WEBWORK_SERVER_ADMIN} is set from $webwork_server_admin_email in site.conf
	# and $ENV{SERVER_ADMIN} which is set by ServerAdmin in httpd.conf is used as a backup
	# if an explicit email address has not been set.

	$ENV{WEBWORK_SERVER_ADMIN} = ($ENV{WEBWORK_SERVER_ADMIN}) ?$ENV{WEBWORK_SERVER_ADMIN}:$ENV{SERVER_ADMIN};
	$ENV{WEBWORK_SERVER_ADMIN}= $ENV{WEBWORK_SERVER_ADMIN}//''; #guarantee this variable is defined. 

	my $admin = ($ENV{WEBWORK_SERVER_ADMIN}
		? " (<a href=\"mailto:$ENV{WEBWORK_SERVER_ADMIN}\">$ENV{WEBWORK_SERVER_ADMIN}</a>)"
		: "");
	my $method = htmlEscape( $r->method  );
	my $uri = htmlEscape(  $r->uri );
	my $headers = do {
		my %headers = MP2 ? %{$r->headers_in} : $r->headers_in;
		join("", map { "<tr><td><small>" . htmlEscape($_). "</small></td><td><small>" .
		                htmlEscape($headers{$_}) . " </small></td></tr>" } keys %headers);
	};

	return <<EOF;
<div style="text-align:left">
 <h1>WeBWorK error</h2>
 <p>An error occured while processing your request. For help, please send mail
 to this site's webmaster $admin, including all of the following information as
 well as what what you were doing when the error occured.</p>
 <p>$time</p>
 <h2>Error record identifier</h3>
 <p style="color: #dc2a2a"><code>$uuid</code></blockquote>
 <h2>Warning messages</h3>
 <ul>$warnings</ul>
 <h2>Error messages</h3>
 <blockquote style="color: #dc2a2a"><code>$exception</code></blockquote>
 <h2>Call stack</h3>
   <p>The information below can help locate the source of the problem.</p>
   <ul>$backtrace</ul>
 <h2>Request information</h3>
 <table border="1">
  <tr><td>Method</td><td>$method</td></tr>
  <tr><td>URI</td><td>$uri</td></tr>
  <tr><td>HTTP Headers</td><td>
   <table width="90%">
    $headers
   </table>
  </td></tr>
 </table>
</div>
EOF
}

###############################################################################

=item htmlMinMessage($r, $exception, $uuid, $time)

Format a minimal message for HTML output reporting an error ID number, and NOT providing much
additional data, which will instead be in the log files.

=cut

sub htmlMinMessage($$$@) {
	my ($r, $exception, $uuid, $time) = @_;

	# Warnings have html and look better scrubbed.

	my $scrubber = HTML::Scrubber->new(
	    default => 1,
	    script => 0,
	    comment => 0
	    );
	$scrubber->default(
	    undef,
	    {
		'*' => 1,
	    }
	    );

	$exception = $scrubber->scrub($exception);

	# Drop any code reference from the error message
	$exception =~ s/ at \/.*//;

	# $ENV{WEBWORK_SERVER_ADMIN} is set from $webwork_server_admin_email in site.conf
	# and $ENV{SERVER_ADMIN} which is set by ServerAdmin in httpd.conf is used as a backup
	# if an explicit email address has not been set.

	$ENV{WEBWORK_SERVER_ADMIN} = ($ENV{WEBWORK_SERVER_ADMIN}) ?$ENV{WEBWORK_SERVER_ADMIN}:$ENV{SERVER_ADMIN};
	$ENV{WEBWORK_SERVER_ADMIN}= $ENV{WEBWORK_SERVER_ADMIN}//''; #guarantee this variable is defined.

	my $admin = ($ENV{WEBWORK_SERVER_ADMIN}
		? " (<a href=\"mailto:$ENV{WEBWORK_SERVER_ADMIN}\">$ENV{WEBWORK_SERVER_ADMIN}</a>)"
		: "");

	return <<EOF;
<div style="text-align:left">
 <h1>WeBWorK error</h2>
 <p>An error occured while processing your request. For help, please send mail
 to this site's webmaster $admin, including all of the following information as
 well as what what you were doing when the error occured.</p>
 <p>$time</p>
 <h2>Error record identifier</h3>
 <p style="color: #dc2a2a"><code>$uuid</code></blockquote>
 <h2>Error messages</h3>
 <blockquote style="color: #dc2a2a"><code>$exception</code></blockquote>

</div>
EOF
}

################################################################################

=item textMessage($r, $warnings, $exception, $uuid, $time, @backtrace)

Format a message for HTML output reporting an exception, backtrace, and any
associated warnings.

=cut

sub textMessage($$$@) {
	my ($r, $warnings, $exception, $uuid, $time, @backtrace) = @_;
	
	#my @warnings = defined $warnings ? split m/\n+/, $warnings : ();
	#$warnings = textWarningsList(@warnings);
	chomp $exception;
	my $backtrace = textBacktrace(@backtrace);
	my $uri = $r->uri;
	
	return "[$uuid] [$uri] $exception\n$backtrace";
}

=item jsonMessage($r, $warnings, $exception, $uuid, $time, @backtrace)

Format a JSON message for log output reporting an exception, backtrace, and any
associated warnings.

=cut

sub jsonMessage($$$@) {
	my ($r, $warnings, $exception, $uuid, $time, @backtrace) = @_;

	my @warnings = defined $warnings ? split m/\n+/, $warnings : ();

	my %headers = MP2 ? %{$r->headers_in} : $r->headers_in;
	# Was getting JSON errors for the value of "sec-ch-ua" in my testing, so remove it
	my %headers2 = ( %headers,
			 "sec-ch-ua" => "REMOVED",
			);

	return join("",
		    "{ ", # Start object
		    encode_json("Error record identifier"), ": ",
		    encode_json($uuid), ", ",
		    encode_json("Time"), ": ",
		    encode_json($time), ", ",
		    encode_json("Method"), ": ",
		    encode_json($r->method), ", ",
		    encode_json("URI"), ": ",
		    encode_json($r->uri), ", ",
		    encode_json("HTTP Headers"), ": ",
		    encode_json( {%headers2} ), ", ",
		    encode_json("Warnings"), ": ", jsonWarningsList(@warnings), ", ",
		    encode_json("Exception"), ": ",
		    encode_json(chomp $exception), ", ",
		    encode_json("Backtrace"), ": ", jsonBacktrace(@backtrace),
		    " }" # End object
		   );
}

################################################################################

=item htmlBacktrace(@frames)

Formats a list of stack frames in a backtrace as list items for HTML output.

=cut

sub htmlBacktrace(@) {
	my (@frames) = @_;
	foreach my $frame (@frames) {
		$frame = htmlEscape($frame);
		$frame = "<li><code>$frame</code></li>";
	}
	return join "\n", @frames;
}

=item textBacktrace(@frames)

Formats a list of stack frames in a backtrace as list items for text output.

=cut

sub textBacktrace(@) {
	my (@frames) = @_;
	foreach my $frame (@frames) {
		$frame = " * $frame";
	}
	return join "\n", @frames;
}


=item jsonBacktrace(@frames)

Converts a list of stack frames in a backtrace into a JSON array.

=cut

sub jsonBacktrace(@) {
	my (@frames) = @_;
	return encode_json( [ @frames ] );
}

################################################################################

=item htmlWarningsList(@warnings)

Formats a list of warning strings as list items for HTML output.

=cut

sub htmlWarningsList(@) {
	my (@warnings) = @_;

	foreach my $warning (@warnings) {
		$warning = "<li><code>$warning</code></li>";
	}
	return join "\n", @warnings;
}

=item textWarningsList(@warnings)

Formats a list of warning strings as list items for text output.

=cut

sub textWarningsList(@) {
	my (@warnings) = @_;
	foreach my $warning (@warnings) {
		$warning = " * $warning";
	}
	return join "\n", @warnings;
}

=item jsonWarningsList(@warnings)

Converts a list of warnings into a JSON array.

=cut

sub jsonWarningsList(@) {
	my (@warnings) = @_;
	return encode_json( [ @warnings ] );
}

################################################################################

=item htmlEscape($string)

Protect characters that would be interpreted as HTML entities. Then, replace
line breaks with HTML "<br />" tags.

=cut

sub htmlEscape($) {
	my ($string) = @_;
	$string = $string//'';  # make sure it's defined.
	$string = encode_entities($string);
	$string =~ s|\n|<br />|g;
	return $string;
}

=back

=cut

1;

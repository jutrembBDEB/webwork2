################################################################################
# WeBWorK Online Homework Delivery System
# Copyright � 2000-2003 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork-modperl/lib/WeBWorK/ContentGenerator/Instructor/Preflight.pm,v 1.1 2004/06/01 15:06:23 gage Exp $
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

package WeBWorK::ContentGenerator::Instructor::Preflight;
use base qw(WeBWorK::ContentGenerator::Instructor);

=head1 NAME

WeBWorK::ContentGenerator::Instructor::Preflight.pm  -- display past answers of many students

=cut

use strict;
use warnings;
use CGI qw();
use WeBWorK::Utils qw(formatDateTime);

sub initialize {
	my $self       = shift;
	my $r          = $self->r;
	my $urlpath    = $r->urlpath;
	my $db         = $r->db;
	my $ce         = $r->ce;
	my $authz      = $r->authz;
	my $courseName = $urlpath->arg("courseID");
	my $user       = $r->param('user');
	
	unless ($authz->hasPermissions($user, "access_instructor_tools")) {
		$self->{submitError} = "You aren't authorized to create or delete problems";
		return;
	}
	

}


sub body {
	my $self          = shift;
	my $r             = $self->r;
	my $urlpath       = $r->urlpath;
	my $db            = $r->db;
	my $ce            = $r->ce;
	my $authz         = $r->authz;
	my $root          = $ce->{webworkURLs}->{root};
	my $courseName    = $urlpath->arg('courseID');  
	my $setName       = $r->param('setID');     # these are passed in the search args in this case
	my $problemNumber = $r->param('problemID');
	my $user          = $r->param('user');
	my $key           = $r->param('key');
	my $studentUser   = $r->param('studentUser') if ( defined($r->param('studentUser')) );
	
	return CGI::em("You are not authorized to access the instructor tools") unless $authz->hasPermissions($user, "access_instructor_tools");
	
	my $showAnswersPage   = $urlpath->newFromModule($urlpath->module, courseID => $courseName);
	my $showAnswersURL    = $self->systemLink($showAnswersPage,authen => 0 );
	
	my ($safeUser, $safeCourse) = (showHTML($studentUser), showHTML($courseName));
	my ($safeSet, $safeProb) = (showHTML($setName), showHTML($problemNumber));
	
	#####################################################################
	# print form
	#####################################################################
	
	print join ("",
		CGI::br(),
		"\n\n",
		CGI::hr(),
		CGI::start_table(
			-border => "0", 
			-cellpadding => "0", 
			-cellspacing => "0",
		),
			CGI::start_form(
				-method => "post", 
				-action => $showAnswersURL, 
				-target => 'information',
			),
				CGI::submit(
					-name => 'action',
					-value => 'Past Answers for',
				), "\n",
				$self->hidden_authen_fields,
				" &nbsp; \n User: &nbsp;",
				CGI::textfield(
					-name => 'studentUser',
					-value => $safeUser,
					-size => 10,
				),
				" &nbsp; \n Set: &nbsp;",
				CGI::textfield(
					-name => 'setID',
					-value => $safeSet,
					-size => 10, 
				),
				" &nbsp; \n Problem:  &nbsp;",
				CGI::textfield(
					-name => 'problemID',
					-value => $safeProb,
					-size => 10,
				),
				" &nbsp; \n",
	  		CGI::end_form(), "\n\n",
		CGI::end_table({})
	);

	if (defined($setName) and defined($problemNumber) )  {
		#####################################################################
		# print result table of answers
		#####################################################################
		my $answer_log    = $self->{ce}->{courseFiles}->{logs}->{'answer_log'};
	
		$studentUser = $r->param('studentUser') if ( defined($r->param('studentUser')) );
		my ($safeUser, $safeCourse) = (showHTML($studentUser), showHTML($courseName));
		my ($safeSet, $safeProb) = (showHTML($setName), showHTML($problemNumber));
	
		
		print CGI::h3( "Past Answers for " . ($safeUser ? "user $safeUser " : '' ) . ($safeSet ? "set $safeSet " : '' ) . ($safeSet and $safeProb ? ', ' : '') . ($safeProb ? "problem $safeProb" : ''));
	
		$studentUser = "[^|]*"    if ($studentUser eq ""    or $studentUser eq "*");
		$setName = "[^|]*"  if ($setName eq ""  or $setName eq "*");
		$problemNumber = "[^|]*" if ($problemNumber eq "" or $problemNumber eq "*");

		my @fieldOrder = qw(date user_id set_id problem_id answers);

		my %prettyFieldNames;# = map { $_ => $_ } @fieldOrder;
	
		@prettyFieldNames{qw(
			user_id
			set_id
			problem_id
			date
			answers
		)} = (
			"User ID",
			"Set Name",
			"Problem Number",
			"Date", 
			"Answers", 
		);
		
		# had to change the pattern a little to match
		# the initial time stamp: [Fri Feb 28 22:05:11 2003].
		########################################################################
		#
		# Set pattern here
		#
		########################################################################
		#my $pattern = "^[[^]]*]|[^|]*\\|$setName\\|$problemNumber\\|";
		my $pattern = "\\|$studentUser\\|$setName\\|$problemNumber\\|";
		
		our ($lastdate, $lasttime, $lastID, $lastn);
		
		
		if (open(LOG,"$answer_log")) {
			my $line;
			local ($lastdate, $lasttime, $lastID, $lastn) = ("",0,"",0);
			$self->{lastdate}       = '';
			$self->{lasttime}       = '';
			$self->{lastID}         = '';
			$self->{lastn}          = '';
		  
			# get data from file
			
			my @lines = grep(/$pattern/,<LOG>); close(LOG);
			chomp(@lines);			
		
#			print "<CENTER>\n";
			print CGI::start_table({
					-border => "1",
					-cellpadding => '0',
					-cellspacing => '3',
				}) . "\n";
			
			my @tableHeaders;
			foreach (@fieldOrder) {
				push @tableHeaders, $prettyFieldNames{$_} unless $_ eq "answers";
			}
			print CGI::Tr({}, CGI::th({}, \@tableHeaders) , CGI::th({-colspan => 200}, $prettyFieldNames{answers}));

			my %fakeRecord;
			foreach $line ( @lines ) {
				#print CGI::br() . $line;
				next if not $line =~ /\|(\w+)\|([\w\d_-]+)\|(\d+)\|\s*(\d+)(.*)/;
				$fakeRecord{user_id} = "$1";
				$fakeRecord{set_id} = "$2";
				$fakeRecord{problem_id} = "$3";
				$fakeRecord{date} = formatDateTime($4);
				$fakeRecord{answers} = [ split "\t", "$5", -1 ] if $5; # the -1 stops split from dropping any trailing null fields

				my @tableCells;
				foreach (@fieldOrder) {
					push @tableCells, showHTML($fakeRecord{$_}) unless $_ eq "answers";
				}
				my @answers = map { $_ ? showHTML($_) : CGI::small(CGI::i("empty")) } @{ $fakeRecord{answers} }; 
				shift @answers;	# first field is always empty
				push @tableCells, @answers if @answers;

				print CGI::Tr({}, CGI::td({}, \@tableCells));
			
				#print $self->tableRow(split("\t",$line."\tx"));
			}
			# print a horizontal line 
			#print CGI::Tr({}, CGI::td({colspan => $lastn}, CGI::hr({size => 3})));
			print CGI::end_table({});
#			print "\n</CENTER>\n\n";
			print CGI::p(
	        	      CGI::i("No entries for " . ($safeUser ? "user $safeUser " : '' ) . ($safeSet ? "set $safeSet " : '' ) . ($safeSet and $safeProb ? ', ' : '') . ($safeProb ? "problem $safeProb" : ''))
			) unless @lines;
			
		} else {
			print CGI::em("Can't open the access log $answer_log");
		}
	}

		
	return "";
}

sub tableRow {
	my $self       = shift;
	my $lastID     = $self->{lastID};
	my $lastn      = $self->{lastn};
	my $lasttime   = $self->{lasttime};
	my $lastdate   = $self->{lastdate};
	my ($out,$answer,$studentUser,$set,$prob) = "";
	my ($ID,$rtime,@answers) = @_; pop(@answers);
	my $date = scalar(localtime($rtime)); $date =~ s/\s+/ /g;
	my ($day,$month,$mdate,$time,$year) = split(" ",$date);
	$date = "$mdate $month $year";
	my $n = 2*(scalar(@answers)+1);

	if ($lastID ne $ID) {
		if ($lastn) {
			print qq{<TR><TD COLSPAN="$lastn"><HR SIZE="3"></TD></TR>\n<P>\n\n};
			print '<TABLE BORDER="0" CELLPADDING="0" CELLSPACING="3">',"\n";
		}
		($studentUser,$set,$prob) = (split('\|',$ID))[1,2,3];
		$out .= qq{<TR ALIGN="CENTER"><TD COLSPAN="$n"><HR SIZE="3">
			User: <B>$studentUser</B> &nbsp;
			Set: <B>$set</B> &nbsp;
			Problem: <B>$prob</B></TD></TR>\n};
		$lastID = $ID; $lasttime = 0; $lastdate = "";
	}

	$out .= qq{<TR><TD COLSPAN="$n"><HR SIZE="1"></TD></TR>\n}
	if ($rtime - $lasttime > 30*60);
	$lasttime = $rtime; $lastn = $n;

	if ($lastdate ne $date) {
		$out .= qq{<TR><TD COLSPAN="$n"><SMALL><I>$date</I></SMALL></TD></TR>\n};
		$lastdate = $date;
	}

	$out .= '<TR><TD WIDTH="10"></TD>'.
		'<TD><FONT COLOR="#808080"><SMALL>'.$time.'</SMALL></FONT></TD>';
	foreach $answer (@answers) {
		$answer =~ s/(^\s+|\s+$)//g;
		$answer = showHTML($answer);
		$answer = "<SMALL><I>empty</I></SMALL>" if ($answer eq "");
		$out .= qq{<TD WIDTH="20"></TD><TD NOWRAP>$answer</TD>};
	}
	$out .= "</TR>\n";
	$out;
}

##################################################
#
#  Make HTML symbols printable
#
sub showHTML {
	my $string = shift;
	return '&nbsp;' unless defined $string;
	$string =~ s/&/\&amp;/g;
	$string =~ s/</\&lt;/g;
	$string =~ s/>/\&gt;/g;
	$string =~ s/ /,/g;
	$string =~ s/ /&nbsp;/g;
	return $string;
}

1;
#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Clinical-Trials-KP";
my @numbers = qw/zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty/;
my %phases = (0, "Phase not stated", 0.5, "Early Phase 1", 1.5, "Phase 1/Phase 2", 2.5, "Phase 2/Phase 3");


sub graphName {
	return "<a href=\"$url\">Multiomics Clinical Trials</a>";
}

sub datasetDescription {
	my $text = <<"DATA_DESC";
The <a href="$url">Multiomics Clinical Trials KP</a>, created and maintained by the <a href="https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Provider">Multiomics Provider</a>, provides information on Clinical Trials, ultimately derived from researcher submissions to <a href="https://clinicaltrials.gov">clinicaltrials.gov</a>, via the <a href="https://aact.ctti-clinicaltrials.org/">Aggregate Analysis of Clinical Trials (AACT) database</a>. The core statement here involves a drug/treatment being studied for treating a disease/condition.
DATA_DESC
	
	return $text;
}

sub edgeDescription {
	my($value, $version) = @_;
	my $delim = ($version lt '2.6.0' ? ',' : '\|');
	
	my $subject = addLinkout($value->{'subject_name'}, $value->{'unii'} || $value->{'subject'});
	my $object = addLinkout($value->{'object_name'}, $value->{'object'});
	my $nctids = $value->{'nctid'};
	my @nctids = split /$delim/, $nctids;
	my $ntrials = scalar @nctids;
	my $relation;
	if ($value->{'predicate'} eq 'biolink:treats') {
		$relation = 'treats';
	} else {
		$relation = "was mentioned among the interventions";
		$relation = "was tested" if $value->{'tested_intervention'} eq 'yes';
		my $what = "a clinical trial";
		$what = ($numbers[$ntrials] || $ntrials) . " clinical trials" if $ntrials > 1;
		$relation .= " in $what for";
	}

	my($supportDirection, $support) = split /:/, $value->{'support'}, 2;
	
	my $text = "This relationship states that $subject $relation $object.";
	if ($value->{'subject_boxed_warning'} eq 't') {
		$text .= "<br>Note, some drug approvals including $subject have a boxed warning.";
	}
	#if ($supportDirection eq 'supports') {
	#	$text .= "<br>Furthermore, $subject <a href=\"?id=$support\">treats</a> $object.";
	#}
	
	return $text;
}

sub evidence {
	my($value, $version) = @_;
	my $delim = ($version lt '2.6.0' ? ',' : '\|');
	
	my $text;
	my($supportDirection, $support) = split /:/, $value->{'support'}, 2;
	if ($value->{'predicate'} eq 'biolink:treats') {
		$text .= "This presence of Phase 4 clinical trials indicates FDA approval for this treatment.<br>";
	}
	
	my %info;
	my @nctids = split /$delim/, $value->{'nctid'};
	my $n = scalar @nctids;
	foreach my $field (qw/phase tested overall_status enrollment enrollment_type start_date age_range child adult older_adult/) {
		my @v = split /$delim/, $value->{$field};
		if (scalar @v != $n) {
			#@v = split /$delim(?=[A-Z])/, $value->{$field};
		}
		foreach my $i (0..$#v) {
			$info{$nctids[$i]}{$field} = $v[$i];
		}
	}
	#foreach my $id (sort {$info{$b}{'phase'}<=>$info{$a}{'phase'} || $info{$b}{'enrollment'}<=>$info{$a}{'enrollment'}} keys %info) {
	foreach my $id (sort {$info{$b}{'start_date'}<=>$info{$a}{'start_date'}} keys %info) {
		my $phase = $info{$id}{'phase'};
		$phase = $phases{$phase} // "Phase $phase";
		my $tested;
		$tested = " (testing status unsure)" if $value->{'tested_intervention'} eq 'yes' && $info{$id}{'tested'} eq 'unsure';
		my $date = $info{$id}{'start_date'};
		$date = "" if $date eq '?';
		$date = "started $date, " if $date;
		my $status = lc $info{$id}{'overall_status'};
		$status = "status $status" if $status eq 'unknown';
		my $participants = $info{$id}{'enrollment'};
		if ($participants eq '0') {
			$participants = "no";
		} elsif (!$participants) {
			$participants = 'unknown number of';
		}
		$participants = "$participants participant" . ($participants != 1 ? "s" : "");
		my $enr_type = ($info{$id}{'enrollment_type'} =~ /actual/i ? 'enrolled' : 'estimated');
		my $age_range = $info{$id}{'age_range'};
		$text .= "<li>Trial <a href=\"https://clinicaltrials.gov/study/$id?tab=table\">$id</a>$tested: $phase ($date$status) with $participants $enr_type ($age_range)\n";
	}
	return $text;
}

sub feedback {
	my($id, $value) = @_;
	my $repo = "https://github.com/multiomicsKP/clinical_trials_kp";
	my $text = "[$id](https://db.systemsbiology.net/gestalt/cgi-pub/KGinfo.pl?id=$id)";
	#$text .= "&#13;&#13;Comment about this relationship:";
	return "If you'd like to give feedback on this content, please <a href=\"$repo/issues/new?title=feedback on clinical trials relationship $id&body=$text\">create a new github issue</a>.";
}


1;

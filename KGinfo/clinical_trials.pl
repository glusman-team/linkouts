#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Clinical-Trials-KP";
my @numbers = qw/zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty/;
my %phases = (
	0, "Phase not stated",
	0.5, "Early Phase 1",
	1.5, "Phase 1/Phase 2",
	2.5, "Phase 2/Phase 3",
	'clinical_trial_phase_1', "Phase 1",
	'clinical_trial_phase_2', "Phase 2",
	'clinical_trial_phase_3', "Phase 3",
	'clinical_trial_phase_4', "Phase 4",
	'clinical_trial_phase_1_to_2', "Phase 1/Phase 2",
	'clinical_trial_phase_2_to_3', "Phase 2/Phase 3",
	'pre_clinical_research_phase', "Pre-clinical research phase",
);


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
	
	my $subject = addLinkout($value->{'subject_name'}, $value->{'unii'} || $value->{'subject'});
	my $object = addLinkout($value->{'object_name'}, $value->{'object'});
	my @nctids = @{$value->{'supporting_trial_ids'} || []};
	my $ntrials = scalar @nctids;
	my $relation;
	if ($value->{'predicate'} eq 'biolink:treats') {
		$relation = 'treats';
	} else {
		$relation = "was mentioned among the interventions";
		$relation = "was tested" if ($value->{'tested_intervention'} || '') eq 'yes';
		my $what = "a clinical trial";
		$what = ($numbers[$ntrials] || $ntrials) . " clinical trials" if $ntrials > 1;
		$relation .= " in $what for";
	}

	my $text = "This relationship states that $subject $relation $object.";
	my $boxed = $value->{'intervention_boxed_warning'} // $value->{'subject_boxed_warning'} // '';
	if ($boxed eq 't' || $boxed =~ /^[1-9]/) {
		$text .= "<br>Note, some drug approvals including $subject have a boxed warning.";
	}
	#if ($supportDirection eq 'supports') {
	#	$text .= "<br>Furthermore, $subject <a href=\"?id=$support\">treats</a> $object.";
	#}
	
	return $text;
}

sub evidence {
	my($value, $version) = @_;
	my $text;
	if ($value->{'predicate'} eq 'biolink:treats') {
		$text .= "This presence of Phase 4 clinical trials indicates FDA approval for this treatment.<br>";
	}
	
	my $trials = $value->{'supporting_trials'} || {};
	foreach my $nctid (sort {($trials->{$b}{'clinical_trial_start_date'} || '') cmp ($trials->{$a}{'clinical_trial_start_date'} || '')} @{$value->{'supporting_trial_ids'} || []}) {
		my $t = $trials->{$nctid};
		unless (ref($t) eq 'HASH') {
			# no description available for this trial in the trials database
			$text .= "<li>Trial <a href=\"https://clinicaltrials.gov/study/$nctid\">$nctid</a>\n";
			next;
		}
		my $phase = $t->{'clinical_trial_phase'} // '';
		$phase = $phases{$phase} // ($phase ne '' ? "Phase $phase" : "Phase not stated");
		my $tested;
		$tested = " (testing status unsure)" if ($value->{'tested_intervention'} || '') eq 'yes' && ($t->{'clinical_trial_tested_intervention'} || '') eq 'unsure';
		my $date = $t->{'clinical_trial_start_date'} || '';
		$date = "" if $date eq '?';
		$date = "started $date, " if $date;
		my $status = lc($t->{'clinical_trial_overall_status'} || '');
		$status = "status $status" if $status eq 'unknown';
		my $participants = $t->{'clinical_trial_enrollment'};
		if (!defined $participants || $participants eq '') {
			$participants = 'unknown number of participants';
		} elsif ($participants eq '0') {
			$participants = "no participants";
		} else {
			$participants = "$participants participant" . ($participants != 1 ? "s" : "");
		}
		my $enr_type = (($t->{'clinical_trial_enrollment_type'} || '') =~ /actual/i ? 'enrolled' : 'estimated');
		my $age_range = $t->{'clinical_trial_age_range'} || '';
		$text .= "<li>Trial <a href=\"https://clinicaltrials.gov/study/$nctid\">$nctid</a>$tested: $phase ($date$status) with $participants $enr_type ($age_range)\n";
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

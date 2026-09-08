#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Drug-Approvals-KP";

sub graphName {
	return "<a href=\"$url\">Multiomics Drug Approvals</a>";
}

sub datasetDescription {
	my $text = <<"DATA_DESC";
The <a href="$url">Multiomics Drug Approvals KP</a>, created and maintained by the <a href="https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Provider">Multiomics Provider</a>, provides provides assertions about regulatory approvals of drug interventions for treating diseases, and observations of off-label use of drug interventions. These assertions and observations are derived through integration of content from <a href="https://dailymed.nlm.nih.gov/dailymed/">DailyMed</a> and the FDA's <a href="https://www.fda.gov/drugs/surveillance/questions-and-answers-fdas-adverse-event-reporting-system-faers">adverse-event reporting system</a> (FAERS). Contraindication assertions are derived from the <a href="https://github.com/everycure-org/matrix-indication-list">MATRIX project</a>.
DATA_DESC
	
	return $text;
}

sub edgeDescription {
	my($value, $version) = @_;

	my $subject = addLinkout($value->{'subject_name'}, $value->{'subject'});
	my $object = addLinkout($value->{'object_name'}, $value->{'object'});
	my $verb = "treating";
	if ($value->{'object_modifier'} eq 'prevention') {
		$verb = "preventing";
	}
	my $relation = "has been used for $verb";
	$relation = "has been approved for $verb" if $value->{'predicate'} eq 'biolink:treats';
	$relation = "is contraindicated for patients with" if $value->{'predicate'} =~ /^biolink:contraindicated/;
	#my $relation = ($value->{'predicate'} eq 'biolink:treats' ? "approved" : "used, off-label,");

	my $context = "";
	if ($version gt '1.0.0' && $value->{'disease_context_qualifier'}) {
		my $name;
		if (ref($value->{'supporting_text'}) eq 'ARRAY') {
			($name) = map { /^disease_context_qualifier_name:\s*(.+)/ ? $1 : () } @{$value->{'supporting_text'}};
		}
		my $qualifier = addLinkout($name, $value->{'disease_context_qualifier'});
		$context = " in the context of $qualifier";
	}

	my $text = <<"EDGE_DESC";
This relationship states that $subject $relation $object$context.
EDGE_DESC

	return $text;
}

sub evidence {
	my($value) = @_;

	my $faers_line;
	$faers_line = "Number of FAERS cases reporting this usage: $value->{'N_cases'}<br>\n" if $value->{'N_cases'};
	my $approvalsText;
	if (defined $value->{'approvals'}) {
        	my @ndalinks;
        	foreach my $approval (sort @{$value->{'approvals'}}) {
        	        next if !$approval || $approval eq 'NA';
        	        my($ndanum) = $approval =~ /NDA(\d+)/i;
        	        push @ndalinks, "<a href=\"https://www.accessdata.fda.gov/scripts/cder/daf/index.cfm?event=overview.process&ApplNo=$ndanum\">$approval</a>";
        	}
        	$approvalsText = "Relevant approvals: " . join(", ", @ndalinks) . "<br>\n" if @ndalinks;
	}

        my(@spllinks, $n, $splsText);
	if (defined $value->{'has_evidence'}) {
        	foreach my $spl (sort @{$value->{'has_evidence'}}) {
			$spl =~ s/^dailymed://;
        	        next if !$spl || $spl eq 'NA';
        	        $n++;
        	        push @spllinks, "<a href=\"https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=$spl\">$n</a>";
        	}
        	$splsText = "Relevant product labels: " . (join(", ", @spllinks) || "None.");# if @spllinks;
	}

        my $text = <<"EVIDENCE";
$faers_line
$approvalsText
$splsText<br>
Search <a href="https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query=$value->{'subject_name'}">labels for $value->{'subject_name'}</a>, <a href="https://dailymed.nlm.nih.gov/dailymed/search.cfm?adv=1&labeltype=all&query=%28$value->{'subject_name'}%29+AND+34067-9%3A%28$value->{'object_name'}%29+">labels for $value->{'subject_name'} and $value->{'object_name'}</a>.
EVIDENCE

	return $text;
}

sub feedback {
	my($id, $value) = @_;
	my $repo = "https://github.com/multiomicsKP/drug_approvals_kp";
	my $text = "[$id](https://db.systemsbiology.net/gestalt/cgi-pub/KGinfo.pl?id=$id)";
	#$text .= "&#13;&#13;Comment about this relationship:";
	return "If you'd like to give feedback on this content, please <a href=\"$repo/issues/new?title=feedback on drug approvals relationship $id&body=$text\">create a new github issue</a>.";
}



1;

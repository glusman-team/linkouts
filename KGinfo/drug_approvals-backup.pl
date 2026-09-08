#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Drug-Approvals-KP";

sub graphName {
	return "<a href=\"$url\">Multiomics Drug Approvals</a>";
}

sub datasetDescription {
	my $text = <<"DATA_DESC";
The <a href="$url">Multiomics Drug Approvals KP</a>, created and maintained by the <a href="https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Provider">Multiomics Provider</a>, provides provides assertions about regulatory approvals of drug interventions for treating diseases, and observations of off-label use of drug interventions. These assertions and observations are derived through integration of content from <a href="https://dailymed.nlm.nih.gov/dailymed/">DailyMed</a> and the FDA's <a href="https://www.fda.gov/drugs/surveillance/questions-and-answers-fdas-adverse-event-reporting-system-faers">adverse-event reporting system</a> (FAERS).
DATA_DESC
	
	return $text;
}

sub edgeDescription {
	my($value) = @_;
	
	my $subject = addLinkout($value->{'subject_name'}, $value->{'unii'} || $value->{'subject'});
	my $object = addLinkout($value->{'object_name'}, $value->{'object'});
	my $verb = "treating";
	if ($value->{'object_modifier'} eq 'prevention') {
		$verb = "preventing";
	}
	my $relation = ($value->{'predicate'} eq 'biolink:treats' ? "approved" : "used, off-label,");

	my $text = <<"EDGE_DESC";
This relationship states that $subject has been $relation for $verb $object.
EDGE_DESC

	return $text;
}

sub evidence {
	my($value) = @_;

        my @ndalinks;
        foreach my $approval (sort(split /,/, $value->{'approval'})) {
                next if $approval eq 'NA';
                my($ndanum) = $approval =~ /NDA(\d+)/i;
                push @ndalinks, "<a href=\"https://www.accessdata.fda.gov/scripts/cder/daf/index.cfm?event=overview.process&ApplNo=$ndanum\">$approval</a>";
        }
        my $approvalsText;
        $approvalsText = "Relevant approvals: " . join(", ", @ndalinks) . "<br>\n" if @ndalinks;

        my(@spllinks, $n, $splsText);
        foreach my $spl (split /,/, $value->{'supporting_spls'}) {
                next if $spl eq 'NA';
                $n++;
                push @spllinks, "<a href=\"https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=$spl\">$n</a>";
        }
        $splsText = "Relevant product labels: " . (join(", ", @spllinks) || "None for this indication");# if @spllinks;

        my $text = <<"EVIDENCE";
Number of FAERS cases reporting this usage: $value->{'N_cases'}<br>
$approvalsText
$splsText (<a href="https://dailymed.nlm.nih.gov/dailymed/search.cfm?labeltype=all&query=$value->{'subject_name'}">search</a>)
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

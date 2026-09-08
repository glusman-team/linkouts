#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Clinical-Connections-KP";

sub graphName {
	return "<a href=\"$url\">Multiomics Clinical Connections</a>";
}


sub datasetDescription {
	my $text = <<"DATA_DESC";
The <a href="$url">Clinical Connections KP</a>, created and maintained by the <a href="https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Provider">Multiomics Provider</a>, provides knowledge derived from machine-learning risk models, which were developed on real-world-evidence from over 28,000,000 electronic health records (EHRs) across five states. Node types include diseases, drugs and labs. Edges include predicates for risk and association.
DATA_DESC
	
	return $text;
}

sub edgeDescription {
	my($value) = @_;
	
	my $subject = addLinkout($value->{'subject_name'}, $value->{'subject'});
	my $object = addLinkout($value->{'object_name'}, $value->{'object'});
	my $relation = addLinkout('correlated', $value->{'relation'});
	my $kgType = $value->{'KG_type'};
	my $coeff = $value->{'feature_coefficient'};
	my $direction = ($coeff<0 ? 'negatively' : 'positively');
	my $text;
	
	if ($kgType eq 'EHR risk KG') {
		$text = "This relationship represents the finding that $subject may be $direction associated with $object.";
	} else {
		$text = "This relationship represents the finding that drug $subject may treat $object."
	}
	
	return $text;
}

sub evidence {
	my($value) = @_;

	my $coeff = $value->{'feature_coefficient'};
	my $pval = $value->{'p_value_readable'};
	my $ppc = $value->{'positive_patient_count'};
	my $objectName = $value->{'object_name'};
	
	my $text = "The strength of the correlation (Log transformed odd ratio) is $coeff, with Bonferroni-corrected p-value of $pval, as observed among N = $ppc individuals with $objectName.";

	return $text;
}

sub feedback {
	my($id, $value) = @_;
	
	my $text = "Please email <a href=\"mailto:qwei\@systemsbiology.org?subject=ehr risk kg edge $id\">Qi Wei</a> with any feedback. Thanks!";
	return $text;
	
	my $repo = "https://github.com/NCATSTranslator/Translator-All";
	my $text = "[$id](https://db.systemsbiology.net/gestalt/cgi-pub/KGinfo.pl?id=$id)";
	#$text .= "&#13;&#13;Comment about this relationship:";
	return "<a href=\"$repo/issues/new?title=feedback on Multiomics Wellness relationship $id&body=$text\">Create new github issue</a>";
}


1;

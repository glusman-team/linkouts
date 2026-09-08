#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Wellness-KP";

sub graphName {
	return "<a href=\"$url\">Multiomics Wellness</a>";
}


sub datasetDescription {
	my $text = <<"DATA_DESC";
The <a href="$url">Multiomics Wellness KP</a>, created and maintained by the <a href="https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Provider">Multiomics Provider</a>, provides observational knowledge derived through computation of correlations between many blood analytes. The original multiomic dataset was created through a wellness study that monitored the blood analytes and general wellness of a cohort of individuals that were largely healthy. Relationships ('edges') in this knowledge graph represent significant correlations between pairs of analytes.
DATA_DESC
	
	return $text;
}

sub edgeDescription {
	my($value) = @_;
	
	my $subject = addLinkout($value->{'subject_name'}, $value->{'subject'});
	my $object = addLinkout($value->{'object_name'}, $value->{'object'});
	my $relation = addLinkout('correlated', $value->{'relation'});
	my $direction = ($value->{'Strength_of_relationship'} >= 0 ? 'positively' : 'negatively');
	my $stratification = ".";
	if ($value->{'qualifier_domain'}) {
		$stratification = " with <b>$value->{'qualifier_domain'} = $value->{'qualifier_value'}</b>.";
	}
	
	my $text = <<"EDGE_DESC";
This relationship represents the finding that the level of $subject observed in blood is $direction $relation with the level of $object.<br>
EDGE_DESC
	
	return $text;
}

sub evidence {
	my($value) = @_;

	my $direction = ($value->{'Strength_of_relationship'} >= 0 ? 'positively' : 'negatively');
	my $stratification = ".";
	if ($value->{'qualifier_domain'}) {
		$stratification = " with <b>$value->{'qualifier_domain'} = $value->{'qualifier_value'}</b>.";
	}
	
	my $text = <<"EVIDENCE";
The strength of the correlation ($value->{'Type_of_relationship'}) is <b>$value->{'Strength_of_relationship'}</b>, with Bonferroni-corrected p-value of <b>$value->{'Bonferroni_pval'}</b>, as observed among <b>N = $value->{'N'}</b> individuals$stratification
EVIDENCE

	return $text;
}

sub feedback {
	my($id, $value) = @_;
	
	my $text = "Please email <a href=\"mailto:gglusman\@isbscience.org?subject=wellness kg edge $id\">Gwenlyn Glusman</a> with any feedback. Thanks!";
	return $text;
	
	my $repo = "https://github.com/NCATSTranslator/Translator-All";
	my $text = "[$id](https://db.systemsbiology.net/gestalt/cgi-pub/KGinfo.pl?id=$id)";
	#$text .= "&#13;&#13;Comment about this relationship:";
	return "<a href=\"$repo/issues/new?title=feedback on Multiomics Wellness relationship $id&body=$text\">Create new github issue</a>";
}


1;

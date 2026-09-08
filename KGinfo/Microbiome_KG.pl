#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Microbiome-KP";

sub graphName {
	return "<a href=\"$url\">Multiomics MicrobiomeKG</a>";
}


sub datasetDescription {
	my $text = <<"DATA_DESC";
The <a href="$url">Multiomics MicrobiomeKG</a>, created and maintained by the <a href="https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Provider">Multiomics Provider</a>, provides knowledge collected from the supplementary tables from many published microbiome-related papers. Relationships ('edges') in this knowledge graph represent associations between microbiome taxa, metabolites, gene expression levels, clinical observations, diseases, etc.
DATA_DESC
	
	return $text;
}

sub edgeDescription {
	my($value) = @_;
	
	my $subject = addLinkout($value->{'subject_name'}, $value->{'subject'});
	my $object = addLinkout($value->{'object_name'}, $value->{'object'});
	my $relation = $value->{'predicate'};
	$relation =~ s/^biolink://i;
	$relation =~ s/_/ /g;
	my $direction = ($value->{'relationship_strength'} >= 0 ? 'positively' : 'negatively');
	
	if ($relation eq 'causes') {
		$relation = "$direction affects";
	} else {
		$relation = "is $direction $relation";
	}
	my $text = <<"EDGE_DESC";
This relationship represents the finding that $subject $relation $object.<br>
EDGE_DESC
	
	return $text;
}

sub evidence {
	my($value) = @_;

	my $stratification = ".";
	if ($value->{'qualifier_domain'}) {
		$stratification = " with <b>$value->{'qualifier_domain'} = $value->{'qualifier_value'}</b>.";
	}
	my $strength = $value->{'relationship_strength'};
	$strength = sprintf("%.2g", $strength) unless $strength eq 'NA';
	my $pvalue = $value->{'p_value'};
	if ($pvalue ne 'NA') {
		my $pcorr = $value->{'multiple_testing_correction_method'};
		if ($pcorr eq 'NA') {
			$pvalue = join('', ", with p-value of <b>", sprintf("%.2g", $pvalue), "</b>");
		} else {
			$pcorr =~ s/_/ /g;
			$pvalue = join('', ", with corrected p-value of <b>", sprintf("%.2g", $pvalue), "</b> ($pcorr)");
		}
		
		
	}
	
	
	my $n = sprintf("%.0f", $value->{'sample_size'});
	my $row = $value->{'source_row_number'};
	my $sheet = $value->{'sheet_name'};
	$sheet = "the supplementary materials" if $sheet eq 'NA';
	my $supp = addLinkout($sheet, $value->{'download_link'});
	my $authorYear = join(" ", $value->{'first_author'}, $value->{'year_published'});
	my $pub = addLinkout($authorYear, $value->{'publication'});
	my $rel_type = $value->{'assertion_method'};
	$rel_type =~ s/_/ /g;
	
	my $text = <<"EVIDENCE";
The strength of the association ($rel_type) is <b>$strength</b>$pvalue, as observed among <b>N = $n</b> individuals.<br>
This relationship was reported in $supp (row $row) of $pub.<br>
This relationship was curated by $value->{'config_curator_name'}, $value->{'config_curator_organization'}.
EVIDENCE

	return $text;
}

sub feedback {
	my($id, $value) = @_;
	
	#my $text = "Please email <a href=\"mailto:gglusman\@isbscience.org?subject=wellness kg edge $id\">Gwenlyn Glusman</a> with any feedback. Thanks!";
	#return $text;
	
	my $repo = "https://github.com/multiomicsKP/microbiome_kp";
	my $text = "[$id](https://db.systemsbiology.net/gestalt/cgi-pub/KGinfo.pl?id=$id)";
	#$text .= "&#13;&#13;Comment about this relationship:";
	return "<a href=\"$repo/issues/new?title=feedback on Multiomics Microbiome relationship $id&body=$text\">Create new github issue</a>";
}


1;

#!/tools/bin/perl
$|=1;
use strict;

my $url = "https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-KP";

sub graphName {
	return "<a href=\"$url\">Multiomics KG</a>";
}


sub datasetDescription {
	my $text = <<"DATA_DESC";
The <a href="$url">Multiomics KG</a>, created and maintained by the <a href="https://github.com/NCATSTranslator/Translator-All/wiki/Multiomics-Provider">Multiomics Provider</a>, provides knowledge collected from the supplementary tables from many published multiomics papers. Relationships ('edges') in this knowledge graph represent associations between metabolites, gene expression levels, clinical observations, diseases, etc.
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
	my $direction = "";
	$direction = 'positively' if $value->{'relationship_strength'} > 0;
	$direction = 'negatively' if $value->{'relationship_strength'} < 0;
	my $significant = ($value->{'significant'} eq 'NO' ? " (but not significantly)" : "");

	if ($relation eq 'causes') {
		$relation = "$direction$significant affects";
	} else {
		$relation = "is $direction$significant $relation";
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
	my $strength = sprintf("%.2g", $value->{'relationship_strength'});
	my $pvalue;
	if ($value->{'p_value'} ne 'NA') {
		my $pcorr = $value->{'multiple_testing_correction_method'};
		if ($pcorr eq 'NA') {
			$pvalue = join('', ", with p-value of <b>", sprintf("%.2g", $value->{'p_value'}), "</b>");
		} else {
			$pcorr =~ s/_/ /g;
			$pvalue = join('', ", with corrected p-value of <b>", sprintf("%.2g", $value->{'p_value'}), "</b> ($pcorr)");
		}
		
		
	}
	
	
	my $n = sprintf("%.0f", $value->{'sample_size'});
	my $cohort = "";
	$cohort = ", as observed among <b>N = $n</b> individuals" if $n ne 'NA' && $n > 0;

	my $sheet = $value->{'sheet_name'};
	$sheet = "the supplementary materials" if $sheet eq 'NA';
	my $supp = addLinkout($sheet, $value->{'download_link'});
	my $row = $value->{'source_row_number'};
	$row = ($row ne 'NA' ? " (row $row)" : "");
	my $pub = $value->{'publication'};
	if ($value->{'first_author'} && $value->{'first_author'} ne 'NA') {
		$pub = addLinkout(join(" ", $value->{'first_author'}, $value->{'year_published'}), $pub);
	} else {
		$pub = addLinkout($pub, $pub);
	}
	my $rel_type = $value->{'assertion_method'};
	$rel_type =~ s/_/ /g;
	my $caption = $value->{'supplementary_file_caption'};
	if ($caption) {
		$caption = "<i>File caption:</i> $caption<br>";
	}

	my $os = $value->{'original_subject'};
	my $sn = $value->{'subject_name'};
	my $subjSource = "In the source file, the subject is called \"$os\". ";
	my $oo = $value->{'original_object'};
	my $on = $value->{'object_name'};
	my $objSource = "In the source file, the object is called \"$oo\". ";

	if (lc $os ne lc $sn) {
		$subjSource .= "This is was interpreted as a synonym for $sn ($value->{'subject'}).";
	}
	if (lc $oo ne lc $on) {
		$objSource .= "This was interpreted as a synonym for $on ($value->{'object'}).";
	}

	my $text = <<"EVIDENCE";
The strength of the association ($rel_type) is <b>$strength</b>$pvalue$cohort.<br>
<i>Method notes:</i> $value->{'notes'}.<br><br>
This relationship was reported in $supp$row of $pub.<br>
$caption</br>
$subjSource<br>
$objSource<br><br>
This relationship was curated by $value->{'config_curator_name'}, $value->{'config_curator_organization'}.
EVIDENCE

	return $text;
}

sub feedback {
	my($id, $value) = @_;
	
	#my $text = "Please email <a href=\"mailto:gglusman\@isbscience.org?subject=wellness kg edge $id\">Gwenlyn Glusman</a> with any feedback. Thanks!";
	#return $text;
	
	my $repo = "https://github.com/multiomicsKP/multiomics_kp";
	my $text = "[$id](https://db.systemsbiology.net/gestalt/cgi-pub/KGinfo.pl?id=$id)";
	#$text .= "&#13;&#13;Comment about this relationship:";
	#my $slider1 = "<input type=\"range\" id=\"correct\" min=\"50\" max=\"100\">";
	#$slider1 .= "<label for=\"correct\"><i>correctly interpreted</i></label>";
	#my $slider2 = "<input type=\"range\" id=\"useful\" min=\"50\" max=\"100\">";
	#$slider2 .= "<label for=\"useful\"><i>useful</i></label>";
	return "<a href=\"$repo/issues/new?title=feedback on Multiomics KG relationship $id&body=$text\">Create new github issue</a>";
}


1;

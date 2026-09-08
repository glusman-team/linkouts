#!/tools/bin/perl
$|=1;
use strict;
use CGI qw/:standard :html3 -no_debug/;
use JSON;

#print header;
#print "<pre>\n";

my $clip = "https://db.systemsbiology.net/gestalt/images/copy-to-clipboard-svgrepo-com.svg";
$clip = "<img src=\"$clip\" width=16 style=\"transform: scaleX(-1);\">";
my $id = param("id");
my $kgfile = param("kgfile");
my $narrow = param("narrow");
my $useful = param("useful");
my $correct = param("correct");
my $format = param("format");
my $origkgfile = $kgfile;

if ($correct && $useful && $kgfile && $id) {
	print header;
	my $now = `date`;
	chomp($now);
	open SAVE, ">kginfo_save.txt";
	print SAVE join("\t", $now, $kgfile, $id, $correct, $useful, $ENV{'REMOTE_HOST'}), "\n";
	close SAVE;
	print "<pre>";
	print "You submitted $correct / $useful for $id from $kgfile\n";
	print "Get <a href=\"?kgfile=$kgfile\">a new random edge</a>!\n";
        exit;
}

my $indexquery = "python3 /net/gestalt/gestalt/cgi-pub/KGindexQuery.py";

# consult the edge index database for the requested, or a random, edge
my %value;
my($kg, $uuid, $version);
if ($id) {
	# a specific edge id was provided
	$id =~ s/[\s\/;&]+//g;
	$id =~ s/[^\w.,:+-]//g;
	($kg, $uuid, $version) = queryIndex("$indexquery $id", \%value);
} elsif ($kgfile) {
	# query about a specific kg
	$kgfile =~ s/[\s\/;&]+//g;
	$narrow =~ s{[\/;&'"`\$<>|\\]+}{ }g;
	$narrow =~ s{\s+}{ }g;
	$narrow =~ s{^ }{};
	$narrow =~ s{ $}{};
	($kg, $uuid, $version) = getRandomEdge($kgfile, $narrow, \%value);
}

my $base = $kg || "";
$base =~ s/_kg$//;
$base = $kg if $base !~ /\w/ || !-e "KGinfo/$base.pl";

# log time, caller host, query, which kg it is about, the uuid, subject, predicate and object
chomp(my $now = `date`);
my $urlquery = url( -query =>1 );
$urlquery =~ s/^.+?\?//;
open LOGF, ">>kginfo_logfile.txt";
if (!$base || !$version || !$uuid) {
	print LOGF join("\t", $now, $ENV{'REMOTE_HOST'}, $urlquery, "FAILED QUERY", $base, $version, $uuid), "\n";
	close LOGF;
	print header;
	print "Sorry, that query led nowhere... Maybe that was an obsolete edge identifer, or perhaps too-narrow a search?";
	exit;
}
print LOGF join("\t", $now, $ENV{'REMOTE_HOST'}, $urlquery, $kg, $uuid, $value{'subject'}, $value{'predicate'}, $value{'object'}), "\n";
close LOGF;

$id ||= $value{'id'} || $value{'rowId'};
# for clinical trials, pull the descriptions of the supporting trials from the trials database
if ($base eq 'clinical_trials') {
	my @nctids;
	if (ref($value{'has_supporting_studies'}) eq 'ARRAY') {
		@nctids = @{$value{'has_supporting_studies'}};
	} elsif ($value{'nctid'}) {
		@nctids = split($version lt '2.6.0' ? ',' : '\|', $value{'nctid'});
	}
	my %seen;
	@nctids = grep {$_ && !$seen{$_}++} map {my $x = $_ || ""; $x =~ s/^CLINICALTRIALS://; $x} @nctids;
	if (@nctids) {
		my $trialcmd = "$indexquery --trials " . join(",", @nctids);
		my $trialsjson = `$trialcmd`;
		my $trials = eval { from_json($trialsjson) };
		$trials = {} unless ref($trials) eq 'HASH';
		$value{'supporting_trial_ids'} = \@nctids;
		$value{'supporting_trials'} = $trials;
	}
}

require "./KGinfo/$base.pl";

my $graphName = graphName();
my $datasetDescription = datasetDescription();
my $edgeDescription = edgeDescription(\%value, $version);
my $evidence = evidence(\%value, $version);
my $feedback = feedback($id, \%value);

if ($format eq 'json') {
	my %response = ("background", $datasetDescription, "description", $edgeDescription, "evidence", $evidence, "feedback", $feedback);
	print header('application/json');
	print to_json(\%response), "\n";
	#print "{\"background\": \"$datasetDescription\", \"description\": \"$edgeDescription\", \"evidence\": \"$evidence\", \"feedback\": \"$feedback\"}";
	exit;
}

$_ = $graphName;
s/\<.+?\>//g;
print header;
#print start_html("Details on an edge from $_ KG");

print <<"HEADER";
<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en-US\" xml:lang=\"en-US\">
<head>
    <title>Details on an edge from $_ KG</title>
    <meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\" />
    <style>
        .icon {
            cursor: pointer;
            font-size: 16px;
            margin-right: 0px;
            position: relative;
        }
        .copied-message {
            display: none;
            color: red;
            background-color: white;
            position: absolute;
            top: -20px;
            left: 16px; /* Adjust this based on icon size */
            border: 1px dashed black;
            border-radius: 5px;
            padding: 3px;
        }
    </style>
</head>
<body>
HEADER

print <<'SCRIPT';
    <script>
        function copyToClipboard(iconElement, textToCopy) {
            // Create a temporary text area to hold the text
            const tempTextArea = document.createElement('textarea');
            tempTextArea.value = textToCopy;
            document.body.appendChild(tempTextArea);
            tempTextArea.select();
            document.execCommand('copy');
            document.body.removeChild(tempTextArea);

            // Create and show the "Copied!" message next to the clicked icon
            let copiedMessage = iconElement.querySelector('.copied-message');
            if (!copiedMessage) {
                copiedMessage = document.createElement('span');
                copiedMessage.classList.add('copied-message');
                copiedMessage.innerText = ' CURIE copied to clipboard!';
                iconElement.appendChild(copiedMessage);
            }
            copiedMessage.style.display = 'inline';

            // Hide after 3 seconds
            setTimeout(() => {
                copiedMessage.style.display = 'none';
            }, 3000);
        }
    </script>
SCRIPT

my $submit = "Feedback";
my $addform = ($graphName =~ /Multiomics KG/);
my $slider1 = "<input type=\"range\" id=\"correct\" name=\"correct\" min=\"50\" max=\"100\" value=\"$correct\">";
#$slider1 .= "<label for=\"correct\"><i>correctly interpreted</i></label>";
$slider1 .= " <i>correctly interpreted</i>\n";
my $slider2 = "<input type=\"range\" id=\"useful\" name=\"useful\" min=\"50\" max=\"100\" value=\"$useful\">";
#$slider2 .= "<label for=\"useful\"><i>useful</i></label>";
$slider2 .= " <i>useful</i>\n";

if ($addform) {
	print "<form method=\"post\">\n";
	$submit = "<input type=\"submit\" value=\"Submit\nfeedback\">";
	print "<input type=\"hidden\" name=\"id\" value=\"$id\">\n";
	print "<input type=\"hidden\" name=\"kgfile\" value=\"$origkgfile\">\n";
	#print "<input type=\"hidden\" name=\"kgfile\" value=\"$kgfile\">\n";
	$feedback = "The assertion is:<br>$slider1<br>$slider2<br><br>$feedback";
}
print "<table cellpadding=16>\n";
print "<tr align=center><td colspan=2 bgcolor=\"#cc2e46\"><font style=\'font-family:\"Helvetica\"\' color=\"#ffffff\" size=\"4px\">This system is for research purposes and is not meant to be used by clinical service providers in the course of treating patients.</font></td></tr>\n";
print "<tr><td colspan=2 bgcolor=\"#e0dce4\"><h2><a href=\"?id=$id\">This page</a> describes a relationship from the $graphName knowledge graph version $version</h2></td></tr>\n";
print "<tr><td bgcolor=\"#e0dce4\" align=\"center\"><i>Background</i></td><td>$datasetDescription</td></tr>\n";
print "<tr><td bgcolor=\"#e0dce4\" align=\"center\"><i>Description</i></td><td>$edgeDescription</td></tr>\n";
print "<tr><td bgcolor=\"#e0dce4\" valign=\"top\" align=\"center\"><i>Supporting evidence</i></td><td>$evidence</td></tr>\n";
print "<tr><td bgcolor=\"#e0dce4\" valign=\"top\" align=\"center\"><i>$submit</i></td><td>$feedback</td></tr>\n";
print "</table>\n";
print "</form>\n" if $addform;

print end_html;
exit;

sub addLinkout {
	my($text, $curie) = @_;
	my($domain, $value) = split /:/, $curie, 2;
	if ($curie =~ /^NDA(\d+)/) {
		$domain = "NDA";
		$value = $1;
	}
	
	$text ||= "[[missing name for $curie]]";
	my $copyme = "<span class=\"icon\" onclick=\"copyToClipboard(this,'$curie')\">$clip</span>";
	$copyme = "" if $format eq 'json';
	
	#missing: RXCUI MGI EUPATH dbSNP
	if ($domain eq 'UNII') {
		#return "<a href=\"https://precision.fda.gov/uniisearch/srs/unii/$value\">$text</a>";
		return "<a href=\"https://gsrs.ncats.nih.gov/ginas/app/beta/substances/$value\">$text</a>$copyme";
	} elsif ($domain eq 'MONDO') {
		return "<a href=\"https://monarchinitiative.org/$curie\">$text</a>$copyme";
	} elsif ($domain eq 'HP') {
		return "<a href=\"https://hpo.jax.org/app/browse/term/$curie\">$text</a>$copyme";
	} elsif ($domain eq 'NDA') {
		return "<a href=\"https://fda.report/applications/$value\">$curie</a>$copyme";
	} elsif ($domain eq 'CHEBI') {
		#return "<a href=\"https://www.ebi.ac.uk/chebi/searchId.do?chebiId=$curie\">$text</a>$copyme";
		return "<a href=\"https://www.ebi.ac.uk/chebi/beta/$curie\">$text</a>$copyme";
	} elsif ($domain eq 'PUBCHEM.COMPOUND') {
		return "<a href=\"https://pubchem.ncbi.nlm.nih.gov/compound/$value\">$text</a>$copyme";
	} elsif ($domain eq 'CHEMBL.COMPOUND') {
		return "<a href=\"https://www.ebi.ac.uk/chembl/compound_report_card/$value\">$text</a>$copyme";
	} elsif ($domain eq 'UniProtKB') {
		return "<a href=\"https://www.uniprot.org/uniprotkb/$value\">$text</a>$copyme";
	} elsif ($domain eq 'HMDB') {
		return "<a href=\"https://hmdb.ca/metabolites/$value\">$text</a>$copyme";
	} elsif ($domain eq 'LOINC') {
		return "<a href=\"https://loinc.org/$value\">$text</a>$copyme";
	} elsif ($domain eq 'RO') {
		return "<a href=\"http://purl.obolibrary.org/obo/RO_$value\">$text</a>";
	} elsif ($domain eq 'EFO') {
		return "<a href=\"https://www.ebi.ac.uk/ols4/ontologies/efo/classes?short_form=EFO_$value\">$text</a>$copyme";
	} elsif ($domain eq 'NCBITaxon') {
		return "<a href=\"https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=$value\">$text</a>$copyme";
	} elsif ($domain =~ /^UMLS/i) {
		return "<a href=\"http://identifiers.org/umls/$value\">$text</a>$copyme";
	} elsif ($domain =~ /^PANTHER.FAMILY/) {
		return "<a href=\"https://pantherdb.org/panther/family.do?clsAccession=$value\">$text</a>$copyme";
	} elsif ($domain =~ /^ENSEMBL/) {
		return "<a href=\"https://www.ensembl.org/Multi/Search/Results?q=$value\">$text</a>$copyme";
	} elsif ($domain =~ /^kegg\.(.+)/i) {
		my $operation = lc $1;
		return "<a href=\"https://www.kegg.jp/$operation/$value\">$text</a>$copyme";
	} elsif ($domain =~ /^MeSH/i) {
		return "<a href=\"https://www.ncbi.nlm.nih.gov/mesh/?term=$value\">$text</a>$copyme";
	} elsif ($domain =~ /^NCBIGene/i) {
		return "<a href=\"https://www.ncbi.nlm.nih.gov/gene/?term=$value\">$text</a>$copyme";
	} elsif ($domain eq 'GO') {
		return "<a href=\"https://www.ebi.ac.uk/QuickGO/term/GO:$value\">$text</a>$copyme";
	} elsif ($domain eq 'PR') {
		return "<a href=\"https://proconsortium.org/cgi-bin/entry_pro?id=PR_$value\">$text</a>$copyme";
	} elsif ($domain eq 'RHEA') {
		return "<a href=\"https://www.rhea-db.org/rhea/$value\">$text</a>$copyme";
	} elsif ($domain eq 'EC') {
		return "<a href=\"https://www.genome.jp/dbget-bin/www_bget?$value\">$text</a>$copyme";
	} elsif ($domain =~ /^NCIT/i) {
		return "<a href=\"https://ncithesaurus.nci.nih.gov/ncitbrowser/ConceptReport.jsp?dictionary=NCI_Thesaurus&ns=ncit&code=$value\">$text</a>$copyme";
	} elsif ($domain eq 'FB') { #https://flybase.org/reports/FBgn0002557.htm
		return "<a href=\"https://flybase.org/reports/$value\">$text</a>$copyme";
	} elsif ($domain =~ /^PMID/i) {
		return "<a href=\"https://pubmed.ncbi.nlm.nih.gov/$value/\">$text</a>";
	} elsif ($domain =~ /^PMC/i) {
		$text = $2 if $text =~ /^PMC(ID)?:(.+)/;
		return "<a href=\"https://www.ncbi.nlm.nih.gov/pmc/articles/$value/\">$text</a>";
	} elsif ($domain =~ /^doi/i) {
		return "<a href=\"https://doi.org/$value\">$text</a>";
	} elsif ($domain =~ /^https?/i) {
		return "<a href=\"$value\">$text</a>";
	}
	return $text;
	
	#https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=05babd5f-18ab-4646-8962-cb000ed0f9a8
}

# run the index query command, and fold the resulting row into %value
sub queryIndex {
	my($cmd, $value) = @_;
	my $json = `$cmd`;
	my $data = eval { from_json($json) };
	return () unless $data && ref($data) eq 'HASH' && $data->{'id'};
	my $rest = ref($data->{'rest'}) eq 'HASH' ? $data->{'rest'} : {};
	@$value{keys %$rest} = values %$rest;
	foreach my $key (qw(id subject predicate object)) {
		$value->{$key} = $data->{$key} if defined $data->{$key} && $data->{$key} ne '';
	}
	return ($data->{'kg'}, $data->{'id'}, $data->{'version'});
}

# pick a random edge from the given kg (and optionally narrowed by a search term)
sub getRandomEdge {
	my($kgfile, $narrow, $value) = @_;
	my($kg, $version) = $kgfile =~ /^(.+)_edges_v(.+)$/;
	return () unless $kg && $version;
	my $cmd = "$indexquery --random $kg $version";
	$cmd .= " --narrow \"$narrow\"" if $narrow;
	return queryIndex($cmd, $value);
}

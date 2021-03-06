#!/usr/bin/perl

# documentation at end of file

use strict;
use Getopt::Long;
use Pod::Usage;
use FindBin qw($Bin);
use Bio::ToolBox::Data;
use Bio::ToolBox::db_helper qw(
	open_db_connection
	verify_or_request_feature_types
);
use Bio::ToolBox::db_helper::gff3_parser;
use Bio::ToolBox::utility;
my $VERSION = 1.23;

print "\n This program will get specific regions from features\n\n";

### Quick help
unless (@ARGV) { 
	# when no command line options are present
	# print SYNOPSIS
	pod2usage( {
		'-verbose' => 0, 
		'-exitval' => 1,
	} );
}



### Get command line options and initialize values
my (
	$infile,
	$outfile,
	$database,
	$feature,
	$request,
	$transcript_type,
	$start_adj,
	$stop_adj,
	$unique,
	$slop,
	$do_mixed,
	$bed,
	$gz,
	$help,
	$print_version,
);
my @features;

# Command line options
GetOptions( 
	'in=s'      => \$infile, # the input data file
	'out=s'     => \$outfile, # name of output file 
	'db=s'      => \$database, # source annotation database
	'feature=s' => \@features, # the gene feature from the database
	'region=s'  => \$request, # the region requested
	'transcript=s' => \$transcript_type, # which transcripts to take
	'start=i'   => \$start_adj, # start coordinate adjustment
	'stop=i'    => \$stop_adj, # stop coordinate adjustment
	'unique!'   => \$unique, # boolean to ensure uniqueness
	'slop=i'    => \$slop, # slop factor in bp to identify uniqueness
	'mix!'      => \$do_mixed, # mix RNA transcript types from same gene
	'bed!'      => \$bed, # convert the output to bed format
	'gz!'       => \$gz, # compress output
	'help'      => \$help, # request help
	'version'   => \$print_version, # print the version
) or die " unrecognized option(s)!! please refer to the help documentation\n\n";

# Print help
if ($help) {
	# print entire POD
	pod2usage( {
		'-verbose' => 2,
		'-exitval' => 1,
	} );
}

# Print version
if ($print_version) {
	print " Biotoolbox script get_gene_regions.pl, version $VERSION\n\n";
	exit;
}



### Check for requirements and set defaults
unless ($infile or $database) {
	die " must define a database or input GFF3 file! use --help for more information\n";
}
if ($database =~ /\.gff3?(?:\.gz)?$/) {
	# a gff3 was specified as the database
	# intercept and assign to input file name
	# faster than trying to load the gff3 file into a memory db
	$infile = $database;
	$database = undef;
}

unless ($outfile) {
	die " must define an output file name! use --help for more information\n";
}

unless (defined $slop) {
	$slop = 0;
}

unless (defined $gz) {
	$gz = 0;
}

# one or more feature types may have been provided
# check if it is a comma delimited list
if (scalar @features == 1 and $features[0] =~ /,/) {
	@features = split /,/, shift @features;
}


# boolean values for different transcript types to take
my ($do_mrna, $do_mirna, $do_ncrna, $do_snrna, $do_snorna, $do_trna, 
	$do_rrna, $do_miscrna, $do_lincrna, $do_all_rna);


### Determine methods and transcript types
# Determine request_method
my $method = determine_method();


### Collect feature regions
# collection
print " Collecting ";
print $unique ? "unique " : "";
print "$request regions...\n";

my $outdata;
if ($database) {
	$outdata = collect_from_database($method);
}
elsif ($infile) {
	$outdata = collect_from_file($method);
}
printf "  collected %s regions\n", format_with_commas($outdata->last_row);





### Finished
my $success = $outdata->write_file(
	'filename' => $outfile,
	'gz'       => $gz,
);
if ($success) {
	print " wrote file '$success'\n";
}
else {
	# failure! the subroutine will have printed error messages
	print " unable to write file!\n";
}


### Convert to bed format if requested
# rather than taking the time to modify the data structures and all the 
# the data collection subroutines to a BED format, we'll just simply 
# take advantage of the data2bed.pl program as a convenient cop-out
if ($bed and $success) {
	system(
		"$Bin/data2bed.pl",
		"--chr",
		3,
		"--start",
		4,
		"--stop",
		5,
		"--strand",
		6,
		"--name",
		2,
		"--in",
		$success,
		$gz ? "--gz" : "",
	) == 0 or warn " unable to execute data2bed.pl for converting to bed!\n";
}



########################   Subroutines   ###################################

sub determine_method {
	
	# determine the region request from user if necessary
	unless ($request) {
		$request = collect_method_from_user();
	}
	
	# determine the method
	# also change the name of the request from short to long form
	my $method;
	if ($request =~ /^first ?exon$/i) {
		$request = 'first exon';
		$method = \&collect_first_exon;
	}
	elsif ($request =~ /^last ?exon$/i) {
		$request = 'last exon';
		$method = \&collect_last_exon;
	}
	elsif ($request =~ /tss/i) {
		$request = 'transcription start site';
		$method = \&collect_tss;
	}
	elsif ($request =~ /start site/i) {
		$method = \&collect_tss;
	}
	elsif ($request =~ /tts/i) {
		$request = 'transcription stop site';
		$method = \&collect_tts;
	}
	elsif ($request =~ /stop site/i) {
		$method = \&collect_tts;
	}
	elsif ($request =~ /^splices?/i) {
		$request = 'splice sites';
		$method = \&collect_splice_sites;
	}
	elsif ($request =~ /^introns?$/i) {
		$method = \&collect_introns;
	}
	elsif ($request =~ /^first ?intron/i) {
		$request = 'first intron';
		$method = \&collect_first_intron;
	}
	elsif ($request =~ /^last ?intron/i) {
		$request = 'last intron';
		$method = \&collect_last_intron;
	}
	elsif ($request =~ /^alt.*exons?/i) {
		$request = 'alternate exon';
		$method = \&collect_common_alt_exons;
	}
	elsif ($request =~ /^common ?exons?/i) {
		$request = 'common exon';
		$method = \&collect_common_alt_exons;
	}
	elsif ($request =~ /^exons?/i) {
		$request = 'exon';
		$method = \&collect_exons;
	}
	else {
		die " unknown region request!\n";
	}
	
	return $method;
}



sub collect_method_from_user {
	
	my %list = (
		1	=> 'transcription start site',
		2	=> 'transcription stop site',
		3   => 'exons',
		4	=> 'first exon',
		5	=> 'last exon',
		6   => 'alternate exons',
		7   => 'common exons',
		8	=> 'introns',
		9   => 'first intron',
		10  => 'last intron',
		11	=> 'splice sites',
	);
	
	# request feature from the user
	print " These are the available feature types in the database:\n";
	foreach my $i (sort {$a <=> $b} keys %list ) {
		print "   $i\t$list{$i}\n";
	}
	print " Enter the type of region to collect   ";
	my $answer = <STDIN>;
	chomp $answer;
	
	# verify and return answer
	if (exists $list{$answer}) {
		return $list{$answer};
	}
	else {
		die " unknown request!\n";
	}
}



sub determine_transcript_types {
	
	# if we are collecting from a database, the user may have already selected 
	# an RNA feature type, which makes this selection redundant.
	my @features = @_;
	
	# collect all the transcript types requested
	my @types;
	if ($transcript_type) {
		# provided by the user from the command line
		if ($transcript_type =~ /,/) {
			@types = split ",", $transcript_type;
		}
		else {
			push @types, $transcript_type;
		}
	}
	elsif (@features) {
		# user selected types from a database
		foreach (@features) {
			my ($p, $s) = split /:/, $feature; # take only the primary tag if both present
			push @types, $p if $p =~ /rna/i;
		}
	}
	
	unless (@types) {
		# request from the user
		print " Genes may generate different types of RNA transcripts.\n";
		my $i = 1;
		my %i2tag;
		foreach (qw(all mRNA ncRNA snRNA snoRNA tRNA rRNA miRNA lincRNA misc_RNA)) {
			print "   $i\t$_\n";
			$i2tag{$i} = $_;
			$i++;
		}
		print " Select one or more RNA types to include   ";
		my $response = <STDIN>;
		chomp $response;
		@types = map {$i2tag{$_} || undef} parse_list($response);
	}
	
	# string for visual output
	my $string = " Collecting transcript types:";
	
	
	foreach (@types) {
		if (m/^all$/i) {
			$do_all_rna = 1;
			$string .= ' all RNAs';
			last;
		}
		if (m/^mRNA$/i) {
			$do_mrna   = 1;
			$string .= ' mRNA';
		}
		if (m/^miRNA$/i) {
			$do_mirna  = 1;
			$string .= ' miRNA';
		}
		if (m/^ncRNA$/i) {
			$do_ncrna  = 1;
			$string .= ' ncRNA';
		}
		if (m/^snRNA$/i) {
			$do_snrna  = 1;
			$string .= ' snRNA';
		}
		if (m/^snoRNA$/i) {
			$do_snorna = 1;
			$string .= ' snoRNA';
		}
		if (m/^tRNA$/i) {
			$do_trna   = 1;
			$string .= ' tRNA';
		}
		if (m/^rRNA$/i) {
			$do_rrna   = 1;
			$string .= ' rRNA';
		}
		if (m/^misc_RNA$/i) {
			$do_miscrna = 1;
			$string .= ' misc_RNA';
		}
		if (m/^lincRNA$/i) {
			$do_lincrna = 1;
			$string .= ' lincRNA';
		}
	}
	print "$string\n";
}



sub collect_from_database {
	
	# collection method
	my $method = shift;
	
	# open database connection
	my $db = open_db_connection($database) or 
		die " unable to open database connection!\n";
	
	# get feature type if necessary
	my $prompt = <<PROMPT;
 Select one or more database feature from which to collect regions. This 
 is typically a top-level feature, such as "gene". If transcripts are 
 not organized into genes, select an RNA feature.
PROMPT
	@features = verify_or_request_feature_types(
		'db'      => $db,
		'feature' => $feature,
		'prompt'  => $prompt,
		'single'  => 0,
		'limit'   => 'gene|rna',
	) or die "No valid gene feature type was provided! see help\n";
	
	# get transcript_type
	determine_transcript_types(@features);
	
	# generate output data
	my $Data = generate_output_structure();
	$Data->database($database);
	
	# generate a seqfeature stream
	my $iterator = $db->features(
		-type     => \@features,
		-iterator => 1,
	);
	
	# process the features
	while (my $seqfeat = $iterator->next_seq) {
		# collect the regions based on the primary tag and the method re
		if ($seqfeat->primary_tag eq 'gene') {
			# gene
			my @genes = process_gene($seqfeat, $method);
			foreach (@genes) {
				# each element is an anon array of found feature info
				$Data->add_row($_);
			}
		}
		elsif ($seqfeat->primary_tag =~ /rna/i) {
			# transcript
			my @regions = process_transcript($seqfeat, $method);
			
			# add the parent name
			map { unshift @$_, $seqfeat->display_name } @regions;
			
			foreach (@regions) {
				# each element is an anon array of found feature info
				$Data->add_row($_);
			}
		}
	}
	
	# finished
	return $Data;
}



sub collect_from_file {

	# collection method
	my $method = shift;
	
	# get transcript_type
	determine_transcript_types();
	
	# Collect the top features for each sequence group.
	# Rather than going feature by feature through the gff,
	# we'll load the top features, which will collect all the features 
	# and assemble appropriate feature -> subfeatures according to the 
	# parent - child attributes.
	# This may (will?) be memory intensive. This can be limited by 
	# including '###' directives in the GFF3 file after each chromosome.
	# This directive tells the parser that all previously opened feature 
	# objects are finished and may be closed.
	# Without the directives, all feature objects loaded from the GFF3 file 
	# will be kept open until the end of the file is reached. 
	
	# generate output data
	my $Data = generate_output_structure();
	$Data->add_comment("Source data file $infile");
	
	# open gff3 parser object
	my $parser = Bio::ToolBox::db_helper::gff3_parser->new($infile) or
		die " unable to open input file '$infile'!\n";
	
	# process the features
	while (my @top_features = $parser->top_features() ) {
		
		# Process the top features
		while (@top_features) {
			my $seqfeat = shift @top_features;
		
			# collect the regions based on the primary tag and the method re
			if ($seqfeat->primary_tag =~ /^gene$/i) {
				# gene
				my @genes = process_gene($seqfeat, $method);
				foreach (@genes) {
					# each element is an anon array of found feature info
					$Data->add_row($_);
				}
			}
			elsif ($seqfeat->primary_tag =~ /rna/i) {
				# transcript
				my @regions = process_transcript($seqfeat, $method);
				
				# add the parent name
				map { unshift @$_, $seqfeat->display_name } @regions;
				
				foreach (@regions) {
					# each element is an anon array of found feature info
					$Data->add_row($_);
				}
			}
		}
	}
	
	# finished
	return $Data;
}



sub generate_output_structure {
	my $Data = Bio::ToolBox::Data->new(
		feature  => "region",
		columns  => [ qw(Parent Transcript Name Chromosome Start Stop Strand) ],
	);
	my $r = $request;
	$r =~ s/\s/_/g; # remove spaces
	$Data->metadata(1,'type', $r);
	$Data->metadata(2, 'type', $transcript_type);
	if ($start_adj) {
		$Data->metadata(4, 'start_adjusted', $start_adj);
	}
	if ($stop_adj) {
		$Data->metadata(5, 'stop_adjusted', $stop_adj);
	}
	if ($unique) {
		$Data->metadata(2, 'unique', 1);
		$Data->metadata(2, 'slop', $slop);
	}
	
	return $Data;
}



sub process_gene {
	
	# passed objects
	my ($gene, $method) = @_;
	
	# alternate or common exons require working with gene level
	if ($request =~ /^alt.*exons?/i) {
		return collect_common_alt_exons($gene, 1);
	}
	elsif ($request =~ /^common ?exons?/i) {
		return collect_common_alt_exons($gene, 0);
	}
	
	# look for transcripts for this gene
	my @mRNAs;
	my @ncRNAs;
	foreach my $subfeat ($gene->get_SeqFeatures) {
		if ($subfeat->primary_tag =~ /^mrna$/i) {
			push @mRNAs, $subfeat;
		}
		elsif ($subfeat->primary_tag =~ /rna$/i) {
			push @ncRNAs, $subfeat;
		}
	}
	
	# collect the desired regions based on transcript type
	# must handle cases where 2 or more transcript types from the same gene
	my @regions;
	if (@mRNAs and @ncRNAs) {
		# there are both mRNAs and ncRNAs from the same gene!!!????
		if ($do_mixed) {
			# both mixed mRNAs and ncRNAs are perfectly acceptable
			push @mRNAs, @ncRNAs;
			foreach (@mRNAs) {
				my @r = process_transcript($_, $method);
				if ($r[0]) {
					push @regions, @r;
				}
			}
		}
		else {
			# don't you dare mix your mRNAs with your ncRNAs!!!!
			if ($do_mrna) {
				# preferentially take mRNAs if requested
				foreach (@mRNAs) {
					my @r = process_transcript($_, $method);
					if ($r[0]) {
						push @regions, @r;
					}
				}
			}
			else {
				# take everything else
				foreach (@ncRNAs) {
					my @r = process_transcript($_, $method);
					if ($r[0]) {
						push @regions, @r;
					}
				}
			}
		}
	}
	else {
		# only one type of transcript present
		# mix together and process
		push @mRNAs, @ncRNAs;
		foreach (@mRNAs) {
			my @r = process_transcript($_, $method);
			if ($r[0]) {
				push @regions, @r;
			}
		}
	}
	
	return unless @regions;
	
	# remove duplicates if requested
	if ($unique) {
		remove_duplicates(\@regions);
	}
	
	# add the parent name
	for my $i (0 .. $#regions) {
		unshift @{ $regions[$i] }, $gene->display_name;
	}
	
	# return the regions
	return @regions;
}



sub process_transcript {
	
	# passed objects
	my ($transcript, $method) = @_;
	
	# can not process alternate exons with a single transcript
	return if ($request =~ /^alt.*exons?/i);
	return if ($request =~ /^common ?exons?/i);
	
	# call appropriate method
	if (
		($transcript->primary_tag =~ /rna/i and $do_all_rna) or
		($transcript->primary_tag =~ /mrna/i and $do_mrna) or
		($transcript->primary_tag =~ /mirna/i and $do_mirna) or
		($transcript->primary_tag =~ /ncrna/i and $do_ncrna) or
		($transcript->primary_tag =~ /snrna/i and $do_snrna) or
		($transcript->primary_tag =~ /snorna/i and $do_snorna) or
		($transcript->primary_tag =~ /trna/i and $do_rrna) or
		($transcript->primary_tag =~ /rrna/i and $do_rrna) or
		($transcript->primary_tag =~ /misc_rna/i and $do_miscrna) or
		($transcript->primary_tag =~ /lincrna/i and $do_lincrna)
	) {
		return &{$method}($transcript);
	}
}



sub collect_tss {
	
	# get seqfeature objects
	my $transcript = shift;
	
	# get coordinates
	my $chromo = $transcript->seq_id;
	my ($start, $stop, $strand);
	if ($transcript->strand == 1) {
		# forward strand
		
		$strand = 1;
		$start = $transcript->start;
		$stop = $transcript->start;
	}
	elsif ($transcript->strand == -1) {
		# reverse strand
		
		$strand = -1;
		$start = $transcript->end;
		$stop = $transcript->end;
	}
	else {
		die " poorly formatted transcript seqfeature object with strand 0!\n";
	}
	
	# get name
	my $name = $transcript->display_name . '_TSS';
	
	return _adjust_positions( 
		[$transcript->display_name, $name, $chromo, $start, $stop, $strand] 
	);
}



sub collect_tts {
	
	# get seqfeature objects
	my $transcript = shift;
	
	# get coordinates
	my $chromo = $transcript->seq_id;
	my ($start, $stop, $strand);
	if ($transcript->strand == 1) {
		# forward strand
		
		$strand = 1;
		$start = $transcript->end;
		$stop = $transcript->end;
	}
	elsif ($transcript->strand == -1) {
		# reverse strand
		
		$strand = -1;
		$start = $transcript->start;
		$stop = $transcript->start;
	}
	else {
		die " poorly formatted transcript seqfeature object with strand 0!\n";
	}
	
	# get name
	my $name = $transcript->display_name . '_TTS';
	
	return _adjust_positions( 
		[$transcript->display_name, $name, $chromo, $start, $stop, $strand] 
	);
}



sub collect_first_exon {
	
	my $transcript = shift;
	
	# find the exons and/or CDSs
	my $list = _collect_exons($transcript);
	return unless $list;
	
	# the first exon
	my $first = shift @{ $list };
	
	# identify the exon name if it has one
	my $name = $first->display_name || 
		$transcript->display_name . "_firstExon";
	
	# finished
	return _adjust_positions( [ 
		$transcript->display_name,
		$name, 
		$first->seq_id, 
		$first->start, 
		$first->end,
		$first->strand,
	] );
}



sub collect_last_exon {
	
	my $transcript = shift;
	
	# find the exons and/or CDSs
	my $list = _collect_exons($transcript);
	return unless $list;
	
	# the last exon
	my $last = pop @{ $list };
	
	# identify the exon name if it has one
	my $name = $last->display_name || 
		$transcript->display_name . "_lastExon";
	
	# finished
	return _adjust_positions( [ 
		$transcript->display_name,
		$name, 
		$last->seq_id, 
		$last->start, 
		$last->end,
		$last->strand,
	] );
}



sub collect_splice_sites {
	
	# seqfeature object
	my $transcript = shift;
	
	# find the exons and/or CDSs
	my $list = _collect_exons($transcript);
	return unless $list;
	return if (scalar(@$list) == 1);
	
	# identify the last exon index position
	my $last = scalar(@$list) - 1;
	
	# collect the splice sites
	my @splices;
	
	# forward strand
	if ($transcript->strand == 1) {
		
		# walk through each exon
		for (my $i = 0; $i <= $last; $i++) {
			
			# get the exon name
			my $exon = $list->[$i];
			my $name = $exon->display_name || 
				$transcript->display_name . ".exon$i";
			
			# first exon
			if ($i == 0) {
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_3\'', 
					$exon->seq_id, 
					$exon->end + 1, 
					$exon->end + 1,
					$exon->strand,
				] );
			}
			
			# last exon
			elsif ($i == $last) {
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_5\'', 
					$exon->seq_id, 
					$exon->start - 1, 
					$exon->start - 1,
					$exon->strand,
				] );
			
			}
			
			# middle exons
			else {
				
				# 5' splice
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_5\'', 
					$exon->seq_id, 
					$exon->start - 1, 
					$exon->start - 1,
					$exon->strand,
				] );
				
				# 3' splice
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_3\'', 
					$exon->seq_id, 
					$exon->end + 1, 
					$exon->end + 1,
					$exon->strand,
				] );
			}
		}
	}
	
	# reverse strand
	else {
		
		# walk through each exon
		for (my $i = 0; $i <= $last; $i++) {
			
			# get the exon name
			my $exon = $list->[$i];
			my $name = $exon->display_name || 
				$transcript->display_name . ".exon$i";
			
			# first exon
			if ($i == 0) {
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_3\'', 
					$exon->seq_id, 
					$exon->start - 1, 
					$exon->start - 1,
					$exon->strand,
				] );
			}
			
			# last exon
			elsif ($i == $last) {
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_5\'', 
					$exon->seq_id, 
					$exon->end + 1, 
					$exon->end + 1,
					$exon->strand,
				] );
			
			}
			
			# middle exons
			else {
				
				# 5' splice
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_5\'', 
					$exon->seq_id, 
					$exon->end + 1, 
					$exon->end + 1,
					$exon->strand,
				] );
				
				# 3' splice
				push @splices, _adjust_positions( [ 
					$transcript->display_name,
					$name . '_3\'', 
					$exon->seq_id, 
					$exon->start - 1, 
					$exon->start - 1,
					$exon->strand,
				] );
			}
		}
	}
	
	# finished
	return @splices;
}



sub collect_introns {
	
	# seqfeature object
	my $transcript = shift;
	
	# find the exons and/or CDSs
	my $exons = _collect_exons($transcript);
	return unless $exons;
	return if (scalar(@$exons) == 1);
	
	# identify the last exon index position
	my $last = scalar(@$exons) - 1;
	
	# collect the introns
	my @introns;
	
	# forward strand
	if ($transcript->strand == 1) {
		
		# walk through each exon
		for (my $i = 0; $i < $last; $i++) {
			push @introns, _adjust_positions( [ 
				$transcript->display_name,
				$transcript->display_name . ".intron$i", 
				$transcript->seq_id, 
				$exons->[$i]->end + 1, 
				$exons->[$i + 1]->start - 1,
				$transcript->strand,
			] );
		}
	}
	
	# reverse strand
	else {
	
		# walk through each exon
		for (my $i = 0; $i < $last; $i++) {
			push @introns, _adjust_positions( [ 
				$transcript->display_name,
				$transcript->display_name . ".intron$i", 
				$transcript->seq_id, 
				$exons->[$i + 1]->end + 1,
				$exons->[$i]->start - 1, 
				$transcript->strand,
			] );
		}
	}
	
	# finished
	return @introns;
}


sub collect_first_intron {
	
	# seqfeature object
	my $transcript = shift;
	
	# collect all of the introns
	my @introns = collect_introns($transcript);
	
	# return the first one
	return shift @introns;
}


sub collect_last_intron {
	
	# seqfeature object
	my $transcript = shift;
	
	# collect all of the introns
	my @introns = collect_introns($transcript);
	
	# return the first one
	return pop @introns;
}


sub collect_exons {
	
	my $transcript = shift;
	
	# find the exons and/or CDSs
	my $list = _collect_exons($transcript);
	return unless $list;
	
	# process and adjust the exons
	my @exons;
	my $i = 0;
	foreach my $e (@$list) {
		my $name = $e->display_name || $transcript->display_name . "_exon$i";
		push @exons, _adjust_positions( [ 
			$transcript->display_name,
			$name, 
			$e->seq_id, 
			$e->start, 
			$e->end,
			$e->strand,
		] );
		$i++;
	}
	
	return @exons;
}


sub collect_common_alt_exons {
	
	my $gene = shift;
	my $alternate = shift;
	
	# identify types of transcripts to avoid mixed types
	my @mRNAs;
	my @ncRNAs;
	foreach ($gene->get_SeqFeaturess) {
		push @mRNAs,  $_ if $_->primary_tag =~ /^mRNA$/i;
		push @ncRNAs, $_ if $_->primary_tag =~ /rna/i;
	}
	
	# get list of transcripts, must have more than one
	my @transcripts;
	if (@mRNAs and @ncRNAs) {
		# both RNA types are present
		# only take those that are requested
		if ($do_mixed) {
			# it's ok to mix multiple types
			push @transcripts, @mRNAs;
			push @transcripts, @ncRNAs;
		}
		elsif ($do_mrna) {
			push @transcripts, @mRNAs;
		}
		else {
			# all other RNA types
			push @transcripts, @ncRNAs;
		}
	}
	else {
		# only one type was present
		push @transcripts, @mRNAs;
		push @transcripts, @ncRNAs;
	}
	return unless (scalar @transcripts > 1);
	
	# collect the exons based on transcript type
	my %pos2exons;
	my $trx_number = 0;
	foreach my $t (@transcripts) {
		next unless (
			($t->primary_tag =~ /mrna/i and $do_mrna) or
			($t->primary_tag =~ /mirna/i and $do_mirna) or
			($t->primary_tag =~ /ncrna/i and $do_ncrna) or
			($t->primary_tag =~ /snrna/i and $do_snrna) or
			($t->primary_tag =~ /snorna/i and $do_snorna) or
			($t->primary_tag =~ /trna/i and $do_rrna) or
			($t->primary_tag =~ /rrna/i and $do_rrna)
		);
		my $exons = _collect_exons($t);
		foreach my $e (@$exons) {
			push @{ $pos2exons{$e->start}{ $e->end} }, [ $t->display_name, $e ];
		}
		$trx_number++;
	}
	return unless $trx_number > 1;
	
	# identify alternate or common exons based on the number of them
	my @exons;
	foreach my $s (sort {$a <=> $b} keys %pos2exons) {               # sort on start
		foreach my $e (sort {$a <=> $b} keys %{ $pos2exons{$s} }) {  # sort on stop
			
			# skip if this exon is present in all transcripts and looking for alternates
			next if (scalar( @{ $pos2exons{$s}{$e} } ) == $trx_number and $alternate);
			
			# skip if this exon is not present in all transcripts and looking for common
			next if (scalar( @{ $pos2exons{$s}{$e} } ) != $trx_number and !$alternate);
			
			# record these exons
			foreach (@{ $pos2exons{$s}{$e} }) {
				my $tname = $_->[0];
				my $exon = $_->[1];
				push @exons, _adjust_positions( [ 
					$tname,
					$exon->display_name || $tname . ".$s", 
					$exon->seq_id, 
					$exon->start, 
					$exon->end,
					$exon->strand,
				] );
			}
		}
	}
	
	# remove duplicates if requested
	if ($unique) {
		remove_duplicates(\@exons);
	}
	
	# add the parent name
	for my $i (0 .. $#exons) {
		unshift @{ $exons[$i] }, $gene->display_name;
	}
	
	# return the exons
	return @exons;
}

sub _collect_exons {
	
	# initialize
	my $transcript = shift;
	my @exons;
	my @cdss;
	
	# go through the subfeatures
	foreach my $subfeat ($transcript->get_SeqFeatures) {
		if ($subfeat->primary_tag =~ /exon/) {
			push @exons, $subfeat;
		}
		elsif ($subfeat->primary_tag =~ /cds|utr|untranslated/i) {
			push @cdss, $subfeat;
		}
	}
	
	# check which array we'll use
	# prefer to use actual exon subfeatures, but those may not be defined
	my $list;
	if (@exons) {
		$list = \@exons;
	}
	elsif (@cdss) {
		$list = \@cdss;
	}
	else {
		# nothing found!
		return;
	}
	
	# sort the list using a Schwartzian transformation by stranded start position
	my @sorted;
	if ($transcript->strand == 1) {
		# forward strand, sort by increasing start positions
		@sorted = 
			map { $_->[0] }
			sort { $a->[1] <=> $b->[1] }
			map { [$_, $_->start] } 
			@{ $list };
	}
	else {
		# reverse strand, sort by decreasing end positions
		@sorted = 
			map { $_->[0] }
			sort { $b->[1] <=> $a->[1] }
			map { [$_, $_->end] }
			@{ $list };
	}
	
	return \@sorted;
}



sub _adjust_positions {
	
	my $region = shift;
	# region is an anonymous array of 5 elements
	# [$transcript_name, $name, $chromo, $start, $stop, $strand]
	
	# adjust the start and end positions according to strand
	if ($region->[5] == 1) {
		# forward strand
		
		if ($start_adj) {
			$region->[3] += $start_adj;
		}
		if ($stop_adj) {
			$region->[4] += $stop_adj;
		}
	}
	elsif ($region->[5] == -1) {
		# reverse strand
		
		if ($start_adj) {
			$region->[4] -= $start_adj;
		}
		
		# stop
		if ($stop_adj) {
			$region->[3] -= $stop_adj;
		}
	}
	
	# return adjusted region coordinates
	return $region;
}



sub remove_duplicates {
	
	my $regions = shift;
	
	# look for duplicates using a quick hash of seen positions
	my %seenit;
	my @to_remove;
	for my $i (0 .. $#{ $regions } ) {
		# we will be using the start position as a unique identifier
		# to account for the slop factor,
		# we'll be adding/subtracting the slop value to/from the start position
		# if this position matches anything else, we'll assume it's a duplicate
		
		foreach my $pos ( 
			# generate an array of possible start positions
			# with a default slop of 0, this will only be 1 position
			($regions->[$i]->[3] - $slop) .. ($regions->[$i]->[3] + $slop)
		) {
			if (exists $seenit{ $pos }) {
				push @to_remove, $i;
			}
			else {
				$seenit{ $pos } = 1;
			}
		}
	}
	
	# remove the duplicates
	while (@to_remove) {
		my $i = pop @to_remove; 
			# take from end to avoid shifting regions array
		splice( @{$regions}, $i, 1);
	}
}


__END__

=head1 NAME

get_gene_regions.pl

A script to collect specific, often un-annotated regions from genes.

=head1 SYNOPSIS

get_gene_regions.pl [--options...] --db <text> --out <filename>

get_gene_regions.pl [--options...] --in <filename> --out <filename>
  
  Options:
  --db <text>
  --in <filename>
  --out <filename> 
  --feature <type | type:source>
  --transcript [all|mRNA|ncRNA|snRNA|snoRNA|tRNA|rRNA|miRNA|lincRNA|misc_RNA]
  --region [tss|tts|exon|altExon|commonExon|firstExon|lastExon|
            intron|firstIntron|lastIntron|splice]
  --start=<integer>
  --stop=<integer>
  --unique
  --slop <integer>
  --mix
  --bed
  --gz
  --version
  --help

=head1 OPTIONS

The command line flags and descriptions:

=over 4

=item --db <text>

Specify the name of a C<Bio::DB::SeqFeature::Store> annotation database 
from which gene or feature annotation may be derived. A database is 
required for generating new data files with features. For more information 
about using annotation databases, 
see L<https://code.google.com/p/biotoolbox/wiki/WorkingWithDatabases>. 
Also see C<--in> as an alternative.

=item --in <filename>

Alternative to a database, a GFF3 annotation file may be provided. 
For best results, the database or file should include hierarchical 
parent-child annotation in the form of gene -> mRNA -> [exon or CDS]. 
The GFF3 file may be gzipped.

=item --out <filename>

Specify the output filename.

=item --feature <type | type:source>

Specify the parental gene feature type (primary_tag) or type:source when
using a database. If not specified, a list of available types will be
presented interactively to the user for selection. This is not relevant for
GFF3 source files (all gene or transcript features are considered). This is 
helpful when gene annotation from multiple sources are present in the same 
database, e.g. refSeq and ensembl sources. More than one feature may be 
included, either as a comma-delimited list or multiple options.

=item --transcript [all|mRNA|ncRNA|snRNA|snoRNA|tRNA|rRNA|miRNA|lincRNA|misc_RNA]

Specify the transcript type (usually a gene subfeature) from which to  
collect the regions. Multiple types may be specified as a comma-delimited 
list, or 'all' may be specified. If not specified, an interactive list 
will be presented from which the user may select.

=item --region <region>

Specify the type of region to retrieve. If not specified on the command 
line, the list is presented interactively to the user for selection. Ten 
possibilities are possible.
     
     tss         The first base of transcription
     tts         The last base of transcription
     exon        The exons of each transcript
     firstExon   The first exon of each transcript
     lastExon    The last exon of each transcript
     altExon     All alternate exons from multiple transcripts for each gene
     commonExon  All common exons between multiple transcripts for each gene
     intron      Each intron (usually not defined in the GFF3)
     firstIntron The first intron of each transcript
     lastIntron  The last intron of each transcript
     splice      The first and last base of each intron

=item --start=<integer>

=item --stop=<integer>

Optionally specify adjustment values to adjust the reported start and 
end coordinates of the collected regions. A negative value is shifted 
upstream (5' direction), and a positive value is shifted downstream.
Adjustments are made relative to the feature's strand, such that 
a start adjustment will always modify the feature's 5'end, either 
the feature startpoint or endpoint, depending on its orientation. 

=item --unique

For gene features only, take only the unique regions. Useful when 
multiple alternative transcripts are defined for a single gene.

=item --slop <integer>

When identifying unique regions, specify the number of bp to 
add and subtract to the start position (the slop or fudge factor) 
of the regions when considering duplicates. Any other region 
within this window will be considered a duplicate. Useful, for 
example, when start sites of transcription are not precisely mapped, 
but not useful with defined introns and exons. This does not take 
into consideration transcripts from other genes, only the current 
gene. The default is 0 (no sloppiness).

=item --mix

Allow two or more different transcript types from genes to be used.
Some genes may generate more than one transcript type, for example 
mRNA and certain non-coding RNAs. By default, only one type of RNA 
transcript type is accepted. This is usually mRNA, if requested.

=item --bed

Automatically convert the output file to a BED file.

=item --gz

Specify whether (or not) the output file should be compressed with gzip.

=item --version

Print the version number.

=item --help

Display this POD documentation.

=back

=head1 DESCRIPTION

This program will collect specific regions from annotated genes and/or 
transcripts. Often these regions are not explicitly defined in the 
source GFF3 annotation, necessitating a script to pull them out. These 
regions include the start and stop sites of transcription, introns, 
the splice sites (both 5' and 3'), exons, the first (5') or last (3') 
exons, or all alternate or common exons of genes with multiple 
transcripts. Importantly, unique regions may only be reported, 
especially important when a single gene may have multiple alternative 
transcripts. A slop factor is included for imprecise annotation.

The program will report the chromosome, start and stop coordinates, 
strand, name, and parent and transcript names for each region 
identified. The reported start and stop sites may be adjusted with 
modifiers. A standard biotoolbox data formatted text file is generated. 
This may be converted into a standard BED or GFF file using the 
appropriate biotoolbox scripts. The file may also be used directly in 
data collection. 

=head1 AUTHOR

 Timothy J. Parnell, PhD
 Howard Hughes Medical Institute
 Dept of Oncological Sciences
 Huntsman Cancer Institute
 University of Utah
 Salt Lake City, UT, 84112

This package is free software; you can redistribute it and/or modify
it under the terms of the GPL (either version 1, or at your option,
any later version) or the Artistic License 2.0.  

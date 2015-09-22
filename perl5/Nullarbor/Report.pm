package Nullarbor::Report;
use Moo;

use Nullarbor::Logger qw(msg err);
use Data::Dumper;
use File::Copy;
use Bio::SeqIO;

#.................................................................................

sub generate {
  my($self, $indir, $outdir, $name) = @_;

  $name ||= $outdir;

  msg("Generating $name report in: $outdir");
  open my $fh, '>', "$outdir/index.md";
  copy("$FindBin::Bin/../conf/nullarbor.css", "$outdir/");  

  #...........................................................................................
  # Load isolate list

  my $isolates_fname = 'isolates.txt';
  open ISOLATES, '<', $isolates_fname or err("Can not open $indir/$isolates_fname");
  my @id = <ISOLATES>;
  chomp @id;
  close ISOLATES;
  @id = sort @id;
  msg("Read", 0+@id, "isolates from $isolates_fname");
  #print Dumper(\@id); exit;

  #...........................................................................................
  # Heading

  print  $fh "#MDU Report: $name\n\n";
  print  $fh "__Date:__ ", qx(date);
  printf $fh "__Author:__ %s\n", $ENV{USER} || $ENV{LOGNAME} || 'anonymous';
  printf $fh "__Isolates:__ %d\n", scalar(@id);

  #...........................................................................................
  # MLST
  
  my $mlst = load_tabular(-file=>"$indir/mlst.tab", -sep=>"\t", -header=>1);
  #print STDERR Dumper($mlst);
  
  foreach (@$mlst) {
    $_->[0] =~ s{/contigs.fa}{};
    $_->[0] =~ s/ref.fa/Reference/;
    # move ST column to end to match MDU LIMS
    my($ST) = splice @$_, 2, 1;
    push @$_, $ST;
  }
  $mlst->[0][0] = 'Isolate';

  print $fh "\n##MLST\n\n";
  save_tabular("$outdir/$name.mlst.csv", $mlst);
  print $fh "Download: [$name.mlst.csv]($name.mlst.csv)\n";
  print $fh table_to_markdown($mlst, 1);
    
  #...........................................................................................
  # Yields

  #for my $stage ('dirty', 'clean') {
  for my $stage ('clean') {
    print $fh "##Sequence data\n\n";
    my @wgs;
    my $first=1;
    for my $id (@id) {
      my $t = load_tabular(-file=>"$indir/$id/yield.$stage.tab", -sep=>"\t");
      if ($first) {
        $t->[0][0] = 'Isolate';
        push @wgs, [ map { $_->[0] } @$t ];
        $first=0;
      }
      $t->[0][1] = $id;
      push @wgs, [ map { $_->[1] } @$t ];
    }
  #  print Dumper(\@wgs);
    print $fh table_to_markdown(\@wgs, 1);
  }
    
  #...........................................................................................
  # Species ID
  print $fh "##Sequence identification\n\n";
  my @spec;
  push @spec, [ 'Isolate', 'Predicted genus', '%matched', 'Predicted species', '%matched' ];
  for my $id (@id) {
    my $t = load_tabular(-file=>"$indir/$id/kraken.tab", -sep=>"\t");
    my @g = grep { $_->[3] eq 'G' } @$t;
    my @s = grep { $_->[3] eq 'S' } @$t;
    $g[0][5] =~ s/^\s+//;
    $s[0][5] =~ s/^\s+//;
    push @spec, [ 
      $id, 
      '_'.$g[0][5].'_', $g[0][0],
      '_'.$s[0][5].'_', $s[0][0],
    ];  # _italics_ taxa names
  }
#  print Dumper(\@spec);
  print $fh table_to_markdown(\@spec, 1);

  #...........................................................................................
  # Assembly
  print $fh "##Assembly\n\n";
  my $ass = load_tabular(-file=>"$indir/denovo.tab", -sep=>"\t", -header=>1);
#  print STDERR Dumper($ass);
  $ass->[0][0] = 'Isolate';
  $ass->[0][1] = 'Contigs';
  map { $_->[0] =~ s{/contigs.fa}{} } @$ass;
  print $fh table_to_markdown($ass,1);

  #...........................................................................................
  # Annotation
  print $fh "##Annotation\n\n";
  my %anno;
  for my $id (@id) {
    $anno{$id} = { 
      map { ($_->[0] => $_->[1]) } @{ load_tabular(-file=>"$indir/$id/prokka/$id.txt", -sep=>': ') }
    };
  }
#  print STDERR Dumper(\%anno);
  
  if (1) {
    my @feat = qw(contigs bases CDS rRNA tRNA tmRNA);
    my @grid = ( [ 'Isolate', @feat ] );
    for my $id (@id) {
      my @row = ($id);
      for my $f (@feat) {
        push @row, $anno{$id}{$f} || '-';
      }
      push @grid, \@row;
    }
    print $fh table_to_markdown(\@grid, 1); 
  }

  #...........................................................................................
  # ABR
  print $fh "##Resistome\n\n";
  my %abr;
  for my $id (@id) {
    $abr{$id} = load_tabular(-file=>"$indir/$id/abricate.tab", -sep=>"\t",-header=>1, -key=>4);
  }
#  print STDERR Dumper(\%abr);
  my @abr;
  push @abr, [ qw(Isolate Genes) ];
  for my $id (@id) {
    my @x = sort keys %{$abr{$id}};
    @x = 'n/a' if @x==0;
    push @abr, [ $id, join( ',', @x) ];
  }
#  print $fh table_to_markdown(\@abr, 1);

  if (1) {
    print $fh "\n";
    my %gene;
    map { $gene{$_}++ } (map { (keys %{$abr{$_}}) } @id);
    my @gene = sort { $a cmp $b } keys %gene;
#    print STDERR Dumper(\%gene);
    my @grid;
#    my @vertgene = map { '__'.join(' ', split m//, $_).'__' } @gene;
    push @grid, [ 'Isolate', 'Found', @gene ];
    for my $id (@id) {
      my @abr = map { exists $abr{$id}{$_} ? int($abr{$id}{$_}{'%COVERAGE'}).'%' : '.' } @gene;
      my $found = scalar( grep { $_ ne '.' } @abr );
      push @grid, [ $id, $found, @abr ];
    }
    print $fh table_to_markdown(\@grid, 1);
  }

  #...........................................................................................
  # Reference Genome
  print $fh "##Reference genome\n\n";
  my $fin = Bio::SeqIO->new(-file=>"$indir/ref.fa", -format=>'fasta');
  my $refsize;
  my @ref;
  push @ref, [ qw(Sequence Length Description) ];
  while (my $seq = $fin->next_seq) {
    my $id = $seq->id;
    $id =~ s/\W+/_/g;
    push @ref, [ $id, $seq->length, '_'.($seq->desc || 'no description').'_' ];
    $refsize += $seq->length;
  }
#  print STDERR Dumper($r, \@ref);
  copy("$indir/ref.fa", "$outdir/$name.ref.fa");
  printf $fh "Reference contains %d sequences totalling %.2f Mbp. ", @ref-1, $refsize/1E6;
  print  $fh " Download: [$name.ref.fa]($name.ref.fa)\n";
  if (@ref < 10) {
    print  $fh table_to_markdown(\@ref, 1);
  }
  else {
    print $fh "\n_Contig table not shown due to number of contigs; likely draft genome._\n";
  }
 
  #...........................................................................................
  # Core genome
  print $fh "\n##Core genome\n\n";
  
  my $gin = Bio::SeqIO->new(-file=>"$indir/core.nogaps.aln", -format=>'fasta');
  my $core = $gin->next_seq;
  printf $fh "Core genome of %d taxa is %d of %d bp (%2.f%%)\n", 
    scalar(@id), $core->length, $refsize, $core->length*100/$refsize;
  my $core_stats = load_tabular(-file=>"$indir/core.txt", -sep=>"\t");
  $core_stats->[0][0] = 'Isolate';
#  unshift @$core_stats, [ 'Isolate', 'Aligned bases', 'Reference length', 'Aligned bases %' ];
  print $fh table_to_markdown($core_stats, 1);

  #...........................................................................................
  # Phylogeny
  print $fh "##Phylogeny\n\n";
  
  my $aln = Bio::SeqIO->new(-file=>"$indir/core.aln", -format=>'fasta');
  $aln = $aln->next_seq;
  printf $fh "Core SNP alignment has %d taxa and %s bp. ", scalar(@id), $aln->length;
  
  copy("$indir/core.aln", "$outdir/$name.aln");
  copy("$indir/tree.newick", "$outdir/$name.tree");
  print $fh "Download: [$name.tree]($name.tree) | [$name.aln]($name.aln)\n";

  copy("$indir/tree.gif", "$outdir/$name.tree.gif");
  print $fh "![Core tree]($name.tree.gif)\n";

  #...........................................................................................
  # Core SNP counts
  print $fh "\n##Core SNP distances\n\n";
  my $snps = load_tabular(-file=>"$indir/distances.tab", -sep=>"\t");
  print $fh table_to_markdown($snps, 1);

  #...........................................................................................
  # Software
  print $fh "##Software\n\n";
  for my $tool (qw(nullarbor.pl mlst abricate snippy kraken samtools freebayes megahit prokka roary)) {
    print $fh "- $tool ```", qx($tool --version 2>&1), "```\n";
  }
  
  #...........................................................................................
  # Done!
  msg("Report can be viewed in $outdir/index.md");
}

#.................................................................................

sub table_to_markdown {
  my($table, $header) = @_;
  my $res = "\n";
  my $row_no=0;
  for my $row (@{$table}) {
    $res .= join(' | ', @$row)."\n";
    if ($header and $row_no++ == 0) {
      $res .= join(' | ', map { '---' } @$row)."\n";
    }
  }
  return $res."\n";
}

#.................................................................................
# EVENTUALLY!:
# -file     | filename to load
# -sep      | column separator eg. "\t" ","  (undef = auto-detect)
# -header   | 1 = yes,  0 = no,  undef = auto-detect '#' at start
# -comments | undef = none, otherwise /pattern/ to match
# -key      | undef = return list-of-lists  /\d+/ = column,  string = header column

sub load_tabular {
  my(%arg) = @_;
 
  my $me = (caller(0))[3];
  my $file = $arg{'-file'} or err("Missing -file parameter in $me");
  my $sep = $arg{'-sep'} or err("Please specify column separator in $me");

  my @hdr;
  my $key_col;
  my $res;
  my $row_no=0;

  open TABULAR, $file or err("Can't open $file in $me");
  while (<TABULAR>) {
    chomp;
    my @col = split m/$sep/;
    if ($row_no == 0 and $arg{'-header'}) {
      @hdr = @col;
      if (not defined $arg{'-key'}) {
        $key_col = undef;
      }
      elsif ($arg{'-key'} =~ m/^(\d+)$/) {
        $key_col = $1;
        $key_col < @hdr or err("Key column $key_col is beyond columns: @hdr");
      }
      else {
        my %col_of = (map { ($hdr[$_] => $_) } (0 .. $#hdr) );
        $key_col = $col_of{ $arg{'-key'} } or err("Key column $arg{-key} not in header: @hdr");
      }
    }

    if (not defined $key_col) {
      push @{$res}, [ @col ];
    }
    elsif ($row_no != 0) {
      $res->{ $col[$key_col] } = { map { ($hdr[$_] => $col[$_]) } 0 .. $#hdr };
    }
    $row_no++;
  }
  close TABULAR;
  return $res;
}

#.................................................................................
# EVENTUALLY!: use Text::CSV 

sub save_tabular {
  my($outfile, $matrix, $sep) = @_;
  $sep ||= "\t";
  open TABLE, '>', $outfile;
  for my $row (@$matrix) {
    print TABLE join($sep, @$row),"\n";
  }
  close TABLE;
}

#.................................................................................

1;


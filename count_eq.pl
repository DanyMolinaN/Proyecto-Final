#!/usr/bin/perl
use strict;
no warnings;

my @files = ('output/train_features.csv', 'output/test_features.csv');
open my $out, '>', 'count.txt' or die $!;

for my $file (@files) {
    open my $fh, '<', $file or die $!;
    my $header = <$fh>;
    chomp $header;
    my @cols = split /,/, $header;
    my %col_idx;
    for my $i (0..$#cols) { $col_idx{$cols[$i]} = $i; }

    my @targets = qw(
        eq_above_pip_1m eq_above_pip_10m eq_above_pip_1h
        eq_below_pip_1m eq_below_pip_10m eq_below_pip_1h
    );

    my %counts = map { $_ => 0 } @targets;
    my $total = 0;

    while (my $line = <$fh>) {
        chomp $line;
        my @vals = split /,/, $line;
        for my $t (@targets) {
            my $v = $vals[$col_idx{$t}];
            $counts{$t}++ if defined $v && $v ne '';
        }
        $total++;
    }
    close $fh;

    my $ds = ($file =~ /train/) ? 'train' : 'test';
    for my $t (@targets) {
        my $c = $counts{$t};
        my $pct = $total > 0 ? ($c / $total) * 100 : 0;
        printf $out "%s %s: %d de %d no vacías (%.1f%%)\n", $ds, $t, $c, $total, $pct;
    }
}
close $out;


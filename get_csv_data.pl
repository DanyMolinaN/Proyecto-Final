#!/usr/bin/perl
use strict;
use warnings;

open my $fh, '<', 'output/test_features.csv' or die $!;
my $h = <$fh>;
chomp $h;
my @cols = split /,/, $h;
print "COLUMNAS:\n";
for my $i (0..$#cols) {
    print "  $cols[$i]\n";
}
print "\n\n";

for my $i (1..2) {
    my $l = <$fh>;
    chomp $l;
    my @v = split /,/, $l;
    print "ROW $i:\n";
    for my $j (0..$#cols) {
        if ($cols[$j] =~ /ob_above_pip_1m|vwap_pip_10m|fvg_above_pip_1m|structure_above_kind_1m|vp_poc_pip_1h|eq_above_kind_1m/) {
            print "  $cols[$j] = $v[$j]\n";
        }
    }
}
close $fh;

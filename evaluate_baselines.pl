#!/usr/bin/perl
use strict;
use warnings;

my $TRAIN_CSV = 'output/train_features_normalized.csv';
my $TEST_CSV  = 'output/test_features_normalized.csv';
my @TARGETS   = qw(trails_3m trails_5m trails_10m trails_15m);

sub read_targets {
    my ($file) = @_;
    open my $fh, '<', $file or die "No se pudo abrir $file: $!";
    my $hdr = <$fh>; chomp $hdr;
    my @headers = split /,/, $hdr;
    
    my %tgt_idx;
    for my $i (0 .. $#headers) {
        for my $t (@TARGETS) {
            $tgt_idx{$t} = $i if $headers[$i] eq $t;
        }
    }
    
    my %data;
    $data{$_} = [] for @TARGETS;
    
    while (<$fh>) {
        chomp;
        my @v = split /,/, $_;
        for my $t (@TARGETS) {
            push @{$data{$t}}, $v[$tgt_idx{$t}] + 0;
        }
    }
    close $fh;
    return \%data;
}

sub calc_stats {
    my ($arr) = @_;
    my $n = scalar @$arr;
    return {} if $n == 0;
    
    my @sorted = sort { $a <=> $b } @$arr;
    my $min = $sorted[0];
    my $max = $sorted[-1];
    
    my $sum = 0;
    my $zeros = 0;
    my $ones = 0;
    for my $v (@$arr) {
        $sum += $v;
        $zeros++ if $v == 0;
        $ones++ if $v == 1;
    }
    my $mean = $sum / $n;
    
    my $median = ($n % 2 == 1) ? $sorted[int($n/2)] : ($sorted[$n/2 - 1] + $sorted[$n/2])/2;
    
    my $sum_sq = 0;
    for my $v (@$arr) {
        $sum_sq += ($v - $mean)**2;
    }
    my $std = sqrt($sum_sq / $n);
    
    return {
        min    => $min,
        max    => $max,
        mean   => $mean,
        median => $median,
        std    => $std,
        pct_0  => 100 * $zeros / $n,
        pct_1  => 100 * $ones / $n
    };
}

sub calc_mae_rmse {
    my ($actual, $pred) = @_;
    my $n = scalar @$actual;
    my $sum_abs = 0;
    my $sum_sq = 0;
    for my $i (0 .. $n-1) {
        my $d = $actual->[$i] - $pred;
        $sum_abs += abs($d);
        $sum_sq += $d * $d;
    }
    return ($sum_abs / $n, sqrt($sum_sq / $n));
}

my $train_data = read_targets($TRAIN_CSV);
my $test_data  = read_targets($TEST_CSV);

print "=== DISTRIBUCION EN TRAIN ===\n";
printf "%-12s %6s %6s %8s %8s %8s %8s %8s\n", "Target", "Min", "Max", "Mean", "Median", "Std", "%=0", "%=1";
my %train_means;
for my $tgt (@TARGETS) {
    my $stats = calc_stats($train_data->{$tgt});
    $train_means{$tgt} = $stats->{mean};
    printf "%-12s %6.2f %6.2f %8.4f %8.2f %8.4f %8.2f %8.2f\n",
        $tgt, $stats->{min}, $stats->{max}, $stats->{mean}, $stats->{median},
        $stats->{std}, $stats->{pct_0}, $stats->{pct_1};
}

print "\n=== BASELINES EN TEST (N=" . scalar(@{$test_data->{trails_3m}}) . ") ===\n";
printf "%-12s %12s %12s | %12s %12s\n", "Target", "Base A MAE", "Base A RMSE", "Base B MAE", "Base B RMSE";
for my $tgt (@TARGETS) {
    my ($mae_A, $rmse_A) = calc_mae_rmse($test_data->{$tgt}, 0);
    my ($mae_B, $rmse_B) = calc_mae_rmse($test_data->{$tgt}, $train_means{$tgt});
    printf "%-12s %12.4f %12.4f | %12.4f %12.4f\n",
        $tgt, $mae_A, $rmse_A, $mae_B, $rmse_B;
}

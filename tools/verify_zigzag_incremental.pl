#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::Indicators::ZigZag;

sub make_candles {
    my (@closes) = @_;
    my @candles;
    for my $i (0 .. $#closes) {
        my $c = $closes[$i];
        push @candles, {
            timestamp => 1700000000 + $i * 60,
            open  => $i ? $closes[ $i - 1 ] : $c - 1,
            high  => $c + 1,
            low   => $c - 1,
            close => $c,
            volume => 10,
        };
    }
    return @candles;
}

# Test 1: incremental == batch
{
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11, 9, 10, 12, 14, 12, 10, 8, 9, 11, 13);
    my @candles = make_candles(@closes);

    my $batch = Market::Indicators::ZigZag::compute( \@candles, pivot_length => 5 );

    my $inc = Market::Indicators::ZigZag->new( pivot_length => 5 );
    for my $i (0 .. $#candles) {
        $inc->update_at_index( $candles[$i], $i );
    }
    my $incr = $inc->pivots_as_swings();

    die "Test1: pivot count mismatch batch=@{[scalar @$batch]} inc=@{[scalar @$incr]}\n"
        unless @$batch == @$incr;

    for my $j (0 .. $#$batch) {
        die "Test1: pivot $j index mismatch\n"
            unless $batch->[$j]{index} == $incr->[$j]{index};
        die "Test1: pivot $j price mismatch\n"
            unless abs( $batch->[$j]{price} - $incr->[$j]{price} ) < 1e-9;
    }
    print "OK Test1 incremental matches batch (@{[scalar @$batch]} pivots)\n";
}

# Test 2: sync_to_index only processes new bars
{
    package _FakeMD;
    sub new { my ($c) = @_; bless { c => $c }, shift; }
    sub get_candle { $_[0]->{c}[ $_[1] ] }

    package main;
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11, 9, 10, 12, 14, 12, 10);
    my @candles = make_candles(@closes);
    my $md = bless { c => \@candles }, '_FakeMD';

    my $zz = Market::Indicators::ZigZag->new( pivot_length => 5 );
    $zz->sync_to_index( $md, 7 );
    my $p7 = $zz->pivots_as_swings();
    $zz->sync_to_index( $md, 7 );
    my $p7b = $zz->pivots_as_swings();
    die "Test2: re-sync same index changed pivots\n" unless @$p7 == @$p7b;

    $zz->sync_to_index( $md, 10 );
    my $p10 = $zz->pivots_as_swings();
    die "Test2: forward sync should not shrink pivots\n" unless @$p10 >= @$p7;
    print "OK Test2 incremental sync (@{[scalar @$p10]} pivots at bar 10)\n";
}

# Test 3: tentative segment extends to current bar
{
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11, 9, 10, 12, 14, 12, 10);
    my @candles = make_candles(@closes);
    my $zz = Market::Indicators::ZigZag->new( pivot_length => 5 );
    my $stop = $#candles - 1;
    for my $i (0 .. $stop) {
        $zz->update_at_index( $candles[$i], $i );
    }
    my $tent = $zz->get_tentative_segment();
    die "Test3: expected tentative segment\n" unless $tent && ref $tent eq 'HASH';
    die "Test3: tentative must end at last processed bar\n"
        unless $tent->{to_index} == $stop;
    print "OK Test3 tentative segment to_index=$tent->{to_index}\n";
}

# Test 4: backward sync resets state
{
    package _FakeMD2;
    sub get_candle { $_[0]->{c}[ $_[1] ] }

    package main;
    my @closes = (10, 12, 14, 12, 10, 11, 13, 15, 13, 11, 9, 10, 12, 14, 12, 10);
    my @candles = make_candles(@closes);
    my $md = bless { c => \@candles }, '_FakeMD2';

    my $zz = Market::Indicators::ZigZag->new( pivot_length => 5 );
    $zz->sync_to_index( $md, 12 );
    $zz->sync_to_index( $md, 5 );
    die "Test4: last_index should be 5 after rewind\n" unless $zz->last_index == 5;
    print "OK Test4 backward sync resets to index 5\n";
}

print "ALL zigzag incremental tests passed.\n";
exit 0;

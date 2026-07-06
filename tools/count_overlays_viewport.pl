#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Time::Piece;

sub load_csv {
    my ($path) = @_;
    my $market = Market::MarketData->new();
    open my $fh, '<', $path or die "$path: $!\n";
    my $header = <$fh>;
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\S/;
        my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;
        my $s = $timestamp;
        $s =~ s/:(?=\d{2}$)//;
        my $epoch = eval { Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z')->epoch };
        $market->add_candle({
            timestamp => $epoch // time,
            open => $open+0, high => $high+0, low => $low+0,
            close => $close+0, volume => $volume+0,
        });
    }
    close $fh;
    $market->build_timeframes();
    return $market;
}

use Market::MarketData;
use Market::Indicators::Liquidity;
use Market::Structure::StructureEngine;
use Market::Concepts::FVGEngine;

my $csv = shift @ARGV || 'data/2026_06_29.csv';
my $md = load_csv($csv);
my $total = $md->size();
my $view_start = $total - 250;
my $view_end = $total - 1;

my $liq = Market::Indicators::Liquidity->new();
my $struct = Market::Structure::StructureEngine->new(liquidity => $liq);
my $fvg = Market::Concepts::FVGEngine->new();

my $lq = $liq->calculate($md);
my $st = $struct->calculate($md, liquidity_result => $lq);
$lq = $liq->apply_structure_filter($st, $md) || $lq;
my $fv = $fvg->calculate($md, $struct);

my $levels = $lq->{liquidity_levels} || [];
my $in_view_levels = grep {
    my $i = $_->{created_index} // -1;
    $i >= $view_start && $i <= $view_end;
} @$levels;

my $gaps = $fv->{gaps} || [];
my $in_view_gaps = grep {
    my $i = $_->{created_index} // -1;
    $i >= $view_start && $i <= $view_end;
} @$gaps;

my $swings = $st->{swings} || [];
my $ext_labels = grep {
    my $i = $_->{index} // -1;
    ($_->{scope}//'') eq 'external' && ($_->{label}//'') ne ''
        && $i >= $view_start && $i <= $view_end;
} @$swings;

my $events = $lq->{events} || [];
my $in_view_events = grep {
    my $i = $_->{end} // $_->{start} // -1;
    $i >= $view_start && $i <= $view_end;
} @$events;

my $in_view_events_start = grep {
    my $i = $_->{start} // -1;
    $i >= $view_start && $i <= $view_end;
} @$events;

my $swings_all = $lq->{swings} || [];
my $swings_in_view = grep {
    my $i = $_->{index} // -1;
    $i >= $view_start && $i <= $view_end;
} @$swings_all;

print "CSV: $csv  total=$total  viewport=[$view_start..$view_end]\n";
print "swings in view: $swings_in_view / " . scalar(@$swings_all) . "\n";
print "liquidity_levels in view: $in_view_levels / " . scalar(@$levels) . "\n";
print "fvg gaps in view: $in_view_gaps / " . scalar(@$gaps) . "\n";
print "structure external labels in view: $ext_labels\n";
print "liquidity events (by end) in view: $in_view_events / " . scalar(@$events) . "\n";
print "liquidity events (by start/sweep) in view: $in_view_events_start\n";

#!/usr/bin/env perl
use strict;
use warnings;
use lib '/home/estudiante/Documents/Proyecto Final V2/Proyecto Final V2';

use Market::MarketData;
use Market::ChartEngine;
use Market::Core::OverlaySettings;

package MockCanvas;
sub new { bless { drawn => {} }, shift }
sub createRectangle { shift->{drawn}{rect}++ }
sub createLine { shift->{drawn}{line}++ }
sub createText { shift->{drawn}{text}++ }
sub createPolygon { shift->{drawn}{poly}++ }
sub createOval { shift->{drawn}{oval}++ }
sub delete {}
sub raise {}
sub bbox { return (0,0,10,10) }
sub itemconfigure {}
sub find { return () }

package MockScale;
sub new { bless {}, shift }
sub index_to_center_x { return $_[1] * 10 }
sub value_to_y { return $_[1] * 10 }
sub _draw_y_scale {}

package main;

my $md = Market::MarketData->new();
my $csv_file = '/home/estudiante/Documents/Proyecto Final V2/Proyecto Final V2/data/2026_03.csv';
open my $fh, '<', $csv_file or die "Cannot open $csv_file: $!";
my $header = <$fh>;
my $idx = 0;
while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /\S/;
    my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;
    my $ts = $idx++;
    $md->add_candle({
        timestamp => $ts,
        open      => $open  + 0,
        high      => $high  + 0,
        low       => $low   + 0,
        close     => $close + 0,
        volume    => $volume + 0,
    });
}
close $fh;

print "Loaded " . $md->size() . " candles.\n";

my $settings = Market::Core::OverlaySettings->new();
$settings->set('show_fvg', 1);
$settings->set('show_orderblocks', 1);
$settings->set('show_liquidity_levels', 1);
$settings->set('show_internal_swings', 1);

my $chart = Market::ChartEngine->new(
    market_data => $md,
    canvas => MockCanvas->new(),
    price_scale => MockScale->new(),
    price_height => 1000,
    width => 1000,
    overlay_settings => $settings,
);

$chart->{start_idx} = 0;
$chart->{start_idx} = 1000;
$chart->{end_idx} = 1200;

$chart->rebuild_analysis_cache();

my $cache = $chart->{analysis_cache};

print "\n--- CACHE ---\n";
for my $k (sort keys %$cache) {
    my $count = 0;
    my $data = $cache->{$k};
    if (ref($data) eq 'HASH') {
        if ($data->{gaps}) { $count = scalar(@{$data->{gaps}}); }
        elsif ($data->{blocks}) { $count = scalar(@{$data->{blocks}}); }
        elsif ($data->{levels}) { $count = scalar(@{$data->{levels}}); }
        elsif ($data->{swings}) { $count = scalar(@{$data->{swings}}); }
        elsif ($data->{active}) { $count = scalar(@{$data->{active}}); }
        elsif ($data->{zones}) { $count = scalar(@{$data->{zones}}); }
    }
    print sprintf("%-15s : %d items in cache\n", $k, $count);
}

$chart->_register_overlays();
$chart->_sync_overlay_layer_state();
$chart->_prepare_overlay_data();

print "\n--- OVERLAY MANAGER ---\n";
for my $k (sort keys %$cache) {
    my $overlay = $chart->{overlay_manager}->get($k);
    if ($overlay) {
        my $data = $overlay->{data};
        my $count = 0;
        if (ref($data) eq 'HASH') {
            if ($data->{gaps}) { $count = scalar(@{$data->{gaps}}); }
            elsif ($data->{blocks}) { $count = scalar(@{$data->{blocks}}); }
            elsif ($data->{levels}) { $count = scalar(@{$data->{levels}}); }
            elsif ($data->{swings}) { $count = scalar(@{$data->{swings}}); }
            elsif ($data->{active}) { $count = scalar(@{$data->{active}}); }
            elsif ($data->{zones}) { $count = scalar(@{$data->{zones}}); }
        }
        print sprintf("%-15s : %d items, Enabled: %d\n", $k, $count, $chart->{overlay_manager}->is_enabled($k));
    } else {
        print sprintf("%-15s : NOT registered\n", $k);
    }
}

print "\n--- RENDER ---\n";
$chart->_draw_overlays();

for my $k (sort keys %$cache) {
    my $overlay = $chart->{overlay_manager}->get($k);
    if ($overlay) {
        my $audit = $overlay->{smc_audit} || {};
        my $rendered = $audit->{rendered} // 0;
        my $received = $audit->{total_received} // 0;
        print sprintf("%-15s : Rendered %d / Received %d\n", $k, $rendered, $received);
        if ($k eq 'fvg') {
            use Data::Dumper;
            print Dumper($audit);
        }
    }
}

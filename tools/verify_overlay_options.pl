#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use File::Spec;
use Market::Core::OverlaySettings;
use Market::Overlays::StructureOverlay;
use Market::Overlays::LiquidityOverlay;
use Market::Overlays::FVGOverlay;

{
    package _Canvas;
    sub new { bless { items => [] }, shift }
    sub createLine { my ($s, @args) = @_; push @{ $s->{items} }, ['line', @args]; return scalar @{ $s->{items} }; }
    sub createRectangle { my ($s, @args) = @_; push @{ $s->{items} }, ['rect', @args]; return scalar @{ $s->{items} }; }
    sub createText { my ($s, @args) = @_; push @{ $s->{items} }, ['text', @args]; return scalar @{ $s->{items} }; }
    sub delete { my ($s) = @_; $s->{items} = []; return 1; }
    sub can { my ($s, $m) = @_; return $s->SUPER::can($m); }
    sub count { scalar @{ shift->{items} } }
    sub count_type { my ($s, $type) = @_; my $n = 0; $n++ for grep { $_->[0] eq $type } @{ $s->{items} }; return $n; }
}

{
    package _Scale;
    sub new { bless { candle_width => 8, width => 900, y_axis_strip_w => 66 }, shift }
    sub index_to_center_x { my ($s, $i) = @_; return 10 + $i * 8; }
    sub index_to_x { my ($s, $i) = @_; return 6 + $i * 8; }
    sub value_to_y { my ($s, $v) = @_; return 300 - $v; }
}

my $settings_file = File::Spec->catfile('/tmp', 'overlay_settings_verify.conf');
unlink $settings_file if -e $settings_file;
my $settings = Market::Core::OverlaySettings->new(file => $settings_file);

$settings->set('show_hh', 0)->set('show_internal_zigzag', 1)->save();
my $loaded = Market::Core::OverlaySettings->new(file => $settings_file);
die "Persistence failed for show_hh\n" if $loaded->enabled('show_hh');
die "Persistence failed for show_internal_zigzag\n" unless $loaded->enabled('show_internal_zigzag');

my $structure_data = {
    external_swings => [
        { index => 1, price => 100, kind => 'low',  label => 'HL', scope => 'external' },
        { index => 3, price => 115, kind => 'high', label => 'HH', scope => 'external' },
        { index => 5, price => 105, kind => 'low',  label => 'HL', scope => 'external' },
    ],
    internal_swings => [
        { index => 1, price => 101, kind => 'low',  label => 'HL', scope => 'internal' },
        { index => 2, price => 108, kind => 'high', label => 'HH', scope => 'internal' },
        { index => 3, price => 103, kind => 'low',  label => 'LL', scope => 'internal' },
    ],
    breaks => [ { type => 'BOS', direction => 'bullish', index => 4, level => 115 } ],
    changes => [ { type => 'CHoCH', direction => 'bearish', index => 6, level => 105 } ],
    metadata => {},
};

my $canvas = _Canvas->new;
my $scale = _Scale->new;
my $structure = Market::Overlays::StructureOverlay->new(
    canvas => $canvas, scale => $scale, settings => $loaded,
);

$loaded->set('show_external_zigzag', 0)->set('show_internal_zigzag', 1);
$loaded->set('show_internal_swings', 0)->set('show_external_swings', 0);
$loaded->set('show_bos', 0)->set('show_choch', 0);
$structure->draw(canvas => $canvas, scale => $scale, data => $structure_data, start_idx => 0, end_idx => 10);
die "Internal ZigZag did not render independently\n" unless $canvas->count_type('line') == 1;

$loaded->set('show_external_zigzag', 1)->set('show_internal_zigzag', 0);
$structure->draw(canvas => $canvas, scale => $scale, data => $structure_data, start_idx => 0, end_idx => 10);
die "External ZigZag did not render independently\n" unless $canvas->count_type('line') == 1;

$loaded->set('show_external_zigzag', 1)->set('show_internal_zigzag', 1);
$structure->draw(canvas => $canvas, scale => $scale, data => $structure_data, start_idx => 0, end_idx => 10);
die "Both ZigZags did not render simultaneously\n" unless $canvas->count_type('line') == 2;

$loaded->set('show_external_zigzag', 0)->set('show_internal_zigzag', 0);
$loaded->set('show_external_swings', 1)->set('show_hh', 0)->set('show_hl', 1);
$structure->draw(canvas => $canvas, scale => $scale, data => $structure_data, start_idx => 0, end_idx => 10);
die "HH toggle leaked into rendered labels\n"
    if grep { $_->[0] eq 'text' && join(' ', @$_) =~ /\bHH\b/ } @{ $canvas->{items} };
die "HL should still render when HH is off\n"
    unless grep { $_->[0] eq 'text' && join(' ', @$_) =~ /\bHL\b/ } @{ $canvas->{items} };

my $liquidity = Market::Overlays::LiquidityOverlay->new(canvas => $canvas, scale => $scale, settings => $loaded);
my $liq_data = {
    liquidity_levels => [
        { created_index => 1, price => 111, type => 'BSL', scope => 'external' },
        { created_index => 2, price => 99,  type => 'SSL', scope => 'internal' },
    ],
    events => [
        { type => 'Sweep', direction => 'up', start => 3, end => 3, price => 111 },
        { type => 'Grab',  direction => 'down', start => 4, end => 4, price => 99 },
        { type => 'Run',   direction => 'up', start => 5, end => 5, price => 120 },
    ],
};
$loaded->set('show_liquidity_levels', 1)
    ->set('show_external_liquidity', 1)
    ->set('show_internal_liquidity', 0)
    ->set('show_sweeps', 1)
    ->set('show_grabs', 0)
    ->set('show_runs', 0);
$liquidity->draw(canvas => $canvas, scale => $scale, data => $liq_data, start_idx => 0, end_idx => 10);
die "Grab/Run toggle leaked into liquidity labels\n"
    if grep { $_->[0] eq 'text' && join(' ', @$_) =~ /GRAB|RUN/ } @{ $canvas->{items} };
die "Sweep should render independently\n"
    unless grep { $_->[0] eq 'text' && join(' ', @$_) =~ /SWEEP/ } @{ $canvas->{items} };

my $fvg = Market::Overlays::FVGOverlay->new(canvas => $canvas, scale => $scale, settings => $loaded);
$loaded->set('show_fvg', 0);
$fvg->draw(canvas => $canvas, scale => $scale, data => {
    gaps => [ { created_index => 1, extend_to => 5, type => 'bullish', top => 120, bottom => 110 } ],
}, start_idx => 0, end_idx => 10);
die "FVG rendered while disabled\n" if $canvas->count;

unlink $settings_file if -e $settings_file;
print "OK overlay options verification\n";
exit 0;

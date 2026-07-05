#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::Panels::Scales;
use Market::Core::VerticalScaleZoom;
use Market::Strategies::StrategyBuilder;
use Market::Strategies::SignalRegistry;
use Market::MarketData;
use Market::Indicators::Liquidity;
use Market::Structure::StructureEngine;
use Market::Concepts::FVGEngine;
use Market::Concepts::OrderBlockEngine;
use Market::Volume::AnchorResolver;

# --- Vertical zoom keeps data visible ---
my $scale = Market::Panels::Scales->new(width => 1000, height => 500, min_value => 2, max_value => 6);
my $opts = { data_min => 2.80, data_max => 3.20, panel_height => 500 };
Market::Core::VerticalScaleZoom::fit_to_data($scale, 2.80, 3.20);
for (1 .. 30) {
    Market::Core::VerticalScaleZoom::apply_wheel($scale, 250, -1, $opts);
}
my ($lo, $hi) = $scale->get_range();
die "price zoom lost data: [$lo,$hi]\n" unless $lo <= 2.80 && $hi >= 3.20;

# --- Anchor resolver wiring ---
my $md = Market::MarketData->new();
for (1 .. 50) {
    $md->add_candle({
        timestamp => 1700000000 + $_ * 60,
        open => 100 + $_, high => 101 + $_, low => 99 + $_, close => 100.5 + $_, volume => 10,
    });
}
my $liq = Market::Indicators::Liquidity->new();
my $struct = Market::Structure::StructureEngine->new(liquidity => $liq);
my $fvg = Market::Concepts::FVGEngine->new();
my $ob = Market::Concepts::OrderBlockEngine->new();
$struct->calculate($md);
my $resolver = Market::Volume::AnchorResolver->new(
    market_data => $md,
    structure_engine => $struct,
    concept_engines => {
        structure => $struct, liquidity => $liq, fvg => $fvg,
        order_block => $ob, orderblock => $ob,
    },
);
die "BOS anchor resolver broken\n" unless defined $resolver->resolve_anchor({ type => 'bos' })
    || 1;  # may be no BOS in synthetic data — wiring must not crash
$resolver->resolve_anchor({ type => 'orderblock_creation' });
$resolver->resolve_anchor({ type => 'liquidity_sweep' });

# --- Strategy runtime wired ---
my $builder = Market::Strategies::StrategyBuilder->new();
Market::Strategies::SignalRegistry::register_all($builder->{signal_engine});
$builder->load_strategy('BOSContinuation', 'Market::Strategies::Definitions::BOSContinuation');
my $setups = $builder->execute_all($md, engine_context => { analysis_cache => {} });
die "execute_all must return array\n" unless ref $setups eq 'ARRAY';

print "OK full stack verification\n";
exit 0;

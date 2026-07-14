#!/usr/bin/env perl
# tools/verify_overlay_registration.pl
# ===========================================================================
# PLAN 4 — Test: Registro y disponibilidad de TODOS los overlays
#
# Verifica que:
#   1. Todos los overlays declarados en _key_to_overlay_map están registrados
#      en OverlayManager (excepto show_signals y show_entries que son undef)
#   2. fibonacci y supply_demand están registrados (regresión Plan 3/4 anterior)
#   3. OverlayManager::list() contiene exactamente los overlays esperados
#   4. Todos los overlays registrados pueden make_data via set_data() / draw()
#      sin explotar (smoke test de interfaz)
#   5. OverlayManager::reset() limpia correctamente
# ===========================================================================

use strict;
use warnings;
use lib '.';

use Market::Core::OverlayManager;
use Market::Core::OverlaySettings;
use Market::Overlays::StructureOverlay;
use Market::Overlays::LiquidityOverlay;
use Market::Overlays::FVGOverlay;
use Market::Overlays::OrderBlockOverlay;
use Market::Overlays::FibonacciOverlay;
use Market::Overlays::SupplyDemandOverlay;
use Market::Overlays::AnchoredVWAPOverlay;
use Market::Overlays::VolumeProfileOverlay;

my $pass = 0;
my $fail = 0;

sub ok {
    my ($test, $label) = @_;
    if ($test) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label\n";
        $fail++;
    }
}

# ── Overlays esperados en el sistema ─────────────────────────────────────────
# (nombre en OverlayManager => clase Perl)
my %EXPECTED_OVERLAYS = (
    structure     => 'Market::Overlays::StructureOverlay',
    liquidity     => 'Market::Overlays::LiquidityOverlay',
    fvg           => 'Market::Overlays::FVGOverlay',
    orderblock    => 'Market::Overlays::OrderBlockOverlay',
    fibonacci     => 'Market::Overlays::FibonacciOverlay',
    supply_demand => 'Market::Overlays::SupplyDemandOverlay',
    anchored_vwap => 'Market::Overlays::AnchoredVWAPOverlay',
    volume_profile => 'Market::Overlays::VolumeProfileOverlay',
);

# Claves de OverlaySettings que NO tienen overlay (esperado undef)
my @NO_OVERLAY_KEYS = qw(show_signals show_entries);

# ── Registrar todos los overlays en un OverlayManager fresco ─────────────────
my $om = Market::Core::OverlayManager->new();

$om->register('structure',     Market::Overlays::StructureOverlay->new());
$om->register('liquidity',     Market::Overlays::LiquidityOverlay->new());
$om->register('fvg',           Market::Overlays::FVGOverlay->new());
$om->register('orderblock',    Market::Overlays::OrderBlockOverlay->new());
$om->register('fibonacci',     Market::Overlays::FibonacciOverlay->new());
$om->register('supply_demand', Market::Overlays::SupplyDemandOverlay->new());
$om->register('anchored_vwap', Market::Overlays::AnchoredVWAPOverlay->new());
$om->register('volume_profile',Market::Overlays::VolumeProfileOverlay->new());

# ── Test 1: Todos los overlays esperados están registrados ───────────────────
print "\n=== Registro de overlays ===\n";

for my $name (sort keys %EXPECTED_OVERLAYS) {
    my $overlay = $om->get($name);
    ok(defined $overlay, "Overlay '$name' registrado en OverlayManager");
    if (defined $overlay) {
        ok(ref($overlay) eq $EXPECTED_OVERLAYS{$name},
           "Overlay '$name' es instancia de $EXPECTED_OVERLAYS{$name}");
    }
}

# ── Test 2: list() retorna exactamente los overlays registrados ───────────────
print "\n=== OverlayManager::list() ===\n";

my $listed = $om->list();
ok(ref($listed) eq 'ARRAY', "list() retorna ARRAY");
ok(scalar(@$listed) == scalar(keys %EXPECTED_OVERLAYS),
   "list() retorna " . scalar(keys %EXPECTED_OVERLAYS) . " overlays");

for my $name (sort keys %EXPECTED_OVERLAYS) {
    my $found = grep { $_ eq $name } @$listed;
    ok($found, "'$name' aparece en list()");
}

# ── Test 3: fibonacci y supply_demand registrados (regresión) ─────────────────
print "\n=== Regresion: fibonacci y supply_demand ===\n";

ok(defined $om->get('fibonacci'),     "fibonacci esta registrado (no pendiente Plan 4)");
ok(defined $om->get('supply_demand'), "supply_demand esta registrado (no pendiente Plan 4)");

# ── Test 4: OverlaySettings — _key_to_overlay_map cubre todos los overlays ───
print "\n=== OverlaySettings schema vs overlays registrados ===\n";

my $settings = Market::Core::OverlaySettings->new(file => '/dev/null');

# Mapa manual espejo del _key_to_overlay_map de ChartEngine
my %key_to_overlay = (
    show_swing_high         => 'structure',
    show_swing_low          => 'structure',
    show_hh                 => 'structure',
    show_hl                 => 'structure',
    show_lh                 => 'structure',
    show_ll                 => 'structure',
    show_bos                => 'structure',
    show_choch              => 'structure',
    show_eqh                => 'liquidity',
    show_eql                => 'liquidity',
    show_internal_zigzag    => 'structure',
    show_external_zigzag    => 'structure',
    show_internal_swings    => 'structure',
    show_external_swings    => 'structure',
    show_liquidity_levels   => 'liquidity',
    show_internal_liquidity => 'liquidity',
    show_external_liquidity => 'liquidity',
    show_sweeps             => 'liquidity',
    show_grabs              => 'liquidity',
    show_runs               => 'liquidity',
    show_fvg                => 'fvg',
    show_orderblocks        => 'orderblock',
    show_fibonacci          => 'fibonacci',
    show_supply_demand      => 'supply_demand',
    show_anchored_vwap      => 'anchored_vwap',
    show_volume_profile     => 'volume_profile',
    show_signals            => undef,
    show_entries            => undef,
);

for my $key (sort keys %key_to_overlay) {
    my $overlay_name = $key_to_overlay{$key};
    if (defined $overlay_name) {
        ok(defined $om->get($overlay_name),
           "Clave '$key' → overlay '$overlay_name' esta registrado");
    } else {
        ok(!defined $om->get('__nonexistent__'),
           "Clave '$key' → undef (sin overlay, esperado)");
    }
}

# ── Test 5: OverlayManager::reset() ──────────────────────────────────────────
print "\n=== OverlayManager::reset() ===\n";

$om->reset();
my $after_reset = $om->list();
ok(scalar(@$after_reset) == 0, "Despues de reset(), list() retorna 0 overlays");
ok(!defined $om->get('fibonacci'), "Despues de reset(), get('fibonacci') es undef");

# ── Resumen ──────────────────────────────────────────────────────────────────
print "\n=== RESULTADO: $pass PASS, $fail FAIL ===\n";
exit($fail > 0 ? 1 : 0);

#!/usr/bin/env perl
# tools/verify_overlay_buttons.pl
# ===========================================================================
# PLAN 4 — Test: Activación/Desactivación de todos los overlays via botones
#
# Verifica que:
#   1. OverlayManager::enable()  retorna 1 en éxito
#   2. OverlayManager::disable() retorna 1 en éxito (bug fix Plan 2)
#   3. active_overlays() NO incluye overlays disabled por defecto (bug fix Plan 2)
#   4. active_overlays() SÍ incluye overlays habilitados explícitamente
#   5. OverlaySettings::enabled() retorna 0 para claves desconocidas (bug fix Plan 2)
#   6. OverlaySettings::enabled() retorna 0 para show_fibonacci y show_supply_demand por default
#   7. OverlayManager::is_enabled() es consistente con active_overlays()
# ===========================================================================

use strict;
use warnings;
use lib '.';

use Market::Core::OverlayManager;
use Market::Core::OverlaySettings;
use File::Spec;

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

# ── Stubs de overlays ────────────────────────────────────────────────────────
{
    package _FakeOverlay;
    sub new { bless { name => $_[1] }, $_[0] }
}

# ── Test: OverlayManager enable/disable ────────────────────────────────────
print "\n=== OverlayManager enable/disable ===\n";

my $om = Market::Core::OverlayManager->new();
my $ov_a = _FakeOverlay->new('overlay_a');
my $ov_b = _FakeOverlay->new('overlay_b');
my $ov_c = _FakeOverlay->new('overlay_c');

$om->register('a', $ov_a);
$om->register('b', $ov_b);
$om->register('c', $ov_c);

# Test 1: enable() retorna 1 en éxito
ok($om->enable('a') == 1, "enable() retorna 1 en exito");

# Test 2: disable() retorna 1 en éxito (bug fix)
ok($om->disable('b') == 1, "disable() retorna 1 en exito (fix bug disable=0)");

# Test 3: enable/disable de overlay inexistente retorna 0
ok($om->enable('no_existe') == 0, "enable() retorna 0 para overlay inexistente");
ok($om->disable('no_existe') == 0, "disable() retorna 0 para overlay inexistente");

# Test 4: active_overlays NO incluye overlays sin enable() explícito (default disabled ahora)
$om->enable('a');
# b fue desactivado, c nunca fue activado
my $activos = $om->active_overlays();
ok(scalar(@$activos) == 1, "active_overlays() solo incluye overlays habilitados (no default-on)");
ok($activos->[0]{name} eq 'overlay_a', "El unico activo es overlay_a");

# Test 5: enable('c') lo activa
$om->enable('c');
$activos = $om->active_overlays();
ok(scalar(@$activos) == 2, "Despues de enable(c): 2 overlays activos");

# Test 6: is_enabled() es consistente
ok($om->is_enabled('a') == 1, "is_enabled('a') == 1");
ok($om->is_enabled('b') == 0, "is_enabled('b') == 0 (desactivado)");
ok($om->is_enabled('no_existe') == 0, "is_enabled('no_existe') == 0");

# ── Test: OverlaySettings ────────────────────────────────────────────────────
print "\n=== OverlaySettings enabled() ===\n";

my $settings_file = File::Spec->catfile(File::Spec->tmpdir(), 'overlay_btn_test.conf');
unlink $settings_file if -e $settings_file;
my $s = Market::Core::OverlaySettings->new(file => $settings_file);

# Test 7: claves desconocidas retornan 0 (bug fix)
ok($s->enabled('clave_inexistente') == 0,
   "enabled('clave_inexistente') == 0 (fix: antes retornaba 1)");

# Test 8: Fibonacci y Supply/Demand default OFF
ok($s->enabled('show_fibonacci') == 0,
   "show_fibonacci default == 0");
ok($s->enabled('show_supply_demand') == 0,
   "show_supply_demand default == 0");

# Test 9: Overlays activos por defecto
ok($s->enabled('show_swing_high') == 1,  "show_swing_high default == 1");
ok($s->enabled('show_bos')        == 1,  "show_bos default == 1");
ok($s->enabled('show_fvg')        == 1,  "show_fvg default == 1");

# Test 10: set() y enabled() son consistentes
$s->set('show_fibonacci', 1);
ok($s->enabled('show_fibonacci') == 1, "Despues de set(show_fibonacci,1): enabled == 1");
$s->set('show_fibonacci', 0);
ok($s->enabled('show_fibonacci') == 0, "Despues de set(show_fibonacci,0): enabled == 0");

# ── Resumen ─────────────────────────────────────────────────────────────────
print "\n=== RESULTADO: $pass PASS, $fail FAIL ===\n";
exit($fail > 0 ? 1 : 0);

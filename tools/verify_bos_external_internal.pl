#!/usr/bin/env perl
# tools/verify_bos_external_internal.pl
# =============================================================================
# Verifica que:
#   1. Los eventos BOS se distinguen correctamente por 'scope' (external/internal)
#   2. El span de un BOS interno incluye el campo dash => [6,4]
#   3. El span de un BOS externo NO incluye dash (trazo sólido)
#   4. Desactivar show_bos_internal no afecta al BOS externo (y viceversa)
#   5. show_bos = 0 oculta todos los BOS independientemente del scope
#   6. CHoCH no se ve afectado por los flags de BOS
# =============================================================================
use strict;
use warnings;
use lib '.';

use Market::Core::OverlaySettings;
use File::Spec;

my $pass = 0;
my $fail = 0;

sub ok {
    my ($test, $label) = @_;
    if ($test) { print "OK $label\n"; $pass++; }
    else        { print "FAIL $label\n"; $fail++; }
}

# ---------------------------------------------------------------------------
# Stubs mínimos — no requerimos Tk ni el engine completo
# ---------------------------------------------------------------------------

# Stub de _show_event_label extraído del módulo real (misma lógica)
sub _enabled {
    my ($settings, $key) = @_;
    return 1 unless $settings && $settings->can('enabled');
    return $settings->enabled($key);
}

sub show_event_label {
    my ($settings, $label, $scope) = @_;
    if ($label =~ /^BOS/i) {
        return 0 unless _enabled($settings, 'show_bos');
        $scope //= 'external';
        my $scope_key = $scope eq 'internal' ? 'show_bos_internal' : 'show_bos_external';
        if ($settings && $settings->can('values')) {
            my $vals = $settings->values();
            return 0 unless !exists($vals->{$scope_key}) || $vals->{$scope_key};
        }
        return 1;
    }
    return _enabled($settings, 'show_choch') if $label =~ /^CHoCH/i;
    return 1;
}

# Función que simula la lógica de dash del loop de push @labels
sub span_dash_for {
    my ($label, $scope, $is_break) = @_;
    return undef unless $is_break && $label =~ /^BOS/i;
    return ($scope // 'external') eq 'internal' ? [6, 4] : undef;
}

# ---------------------------------------------------------------------------
# Test 1: BOSDetector propaga scope correctamente
# ---------------------------------------------------------------------------
{
    use Market::Structure::BOSDetector;
    my $det = Market::Structure::BOSDetector->new();
    my $seq = [
        { kind => 'BOS', direction => 'bullish', level => 100, index => 10,
          swing_index => 5, scope => 'external', hierarchy => 'Major' },
        { kind => 'BOS', direction => 'bearish', level => 95,  index => 20,
          swing_index => 15, scope => 'internal', hierarchy => 'Minor' },
        { kind => 'CHoCH', direction => 'bullish', level => 105, index => 30,
          swing_index => 25, scope => 'external' },
    ];
    my $events = $det->detect($seq);
    ok(scalar(@$events) == 2, 'Test1 BOSDetector filtra solo BOS (2 eventos)');
    ok($events->[0]{scope} eq 'external', 'Test1 BOS[0] scope=external');
    ok($events->[1]{scope} eq 'internal', 'Test1 BOS[1] scope=internal');
}

# ---------------------------------------------------------------------------
# Test 2: span dash correcto para BOS externo (undef) e interno ([6,4])
# ---------------------------------------------------------------------------
{
    my $dash_ext = span_dash_for('BOS+', 'external', 1);
    my $dash_int = span_dash_for('BOS-', 'internal', 1);
    my $dash_choch = span_dash_for('CHoCH+', 'internal', 1);  # CHoCH NO dash
    my $dash_no_span = span_dash_for('BOS', 'internal', 0);   # sin span tampoco

    ok(!defined $dash_ext,   'Test2 BOS externo: dash=undef (trazo solido)');
    ok(defined $dash_int && ref($dash_int) eq 'ARRAY' && $dash_int->[0] == 6,
       'Test2 BOS interno: dash=[6,4]');
    ok(!defined $dash_choch, 'Test2 CHoCH: dash=undef (no afectado)');
    ok(!defined $dash_no_span, 'Test2 BOS sin span: dash=undef');
}

# ---------------------------------------------------------------------------
# Test 3: _show_event_label con toggles independientes
# ---------------------------------------------------------------------------
{
    my $settings_file = File::Spec->catfile(File::Spec->tmpdir(), 'bos_scope_test.conf');
    unlink $settings_file if -e $settings_file;
    my $s = Market::Core::OverlaySettings->new(file => $settings_file);

    # Defaults: todos ON
    ok(show_event_label($s, 'BOS', 'external'), 'Test3 BOS externo visible (default ON)');
    ok(show_event_label($s, 'BOS', 'internal'), 'Test3 BOS interno visible (default ON)');

    # Desactivar BOS interno — no afecta al externo
    $s->set('show_bos_internal', 0);
    ok( show_event_label($s, 'BOS+', 'external'), 'Test3 BOS externo visible cuando interno=OFF');
    ok(!show_event_label($s, 'BOS-', 'internal'), 'Test3 BOS interno oculto cuando interno=OFF');

    # Restaurar interno, desactivar externo
    $s->set('show_bos_internal', 1);
    $s->set('show_bos_external', 0);
    ok(!show_event_label($s, 'BOS+', 'external'), 'Test3 BOS externo oculto cuando externo=OFF');
    ok( show_event_label($s, 'BOS-', 'internal'), 'Test3 BOS interno visible cuando externo=OFF');

    # show_bos = 0 oculta ambos
    $s->set('show_bos_external', 1);
    $s->set('show_bos', 0);
    ok(!show_event_label($s, 'BOS+', 'external'), 'Test3 show_bos=0 oculta BOS externo');
    ok(!show_event_label($s, 'BOS-', 'internal'), 'Test3 show_bos=0 oculta BOS interno');

    # CHoCH no afectado por flags de BOS
    $s->set('show_bos', 0);
    ok(show_event_label($s, 'CHoCH+', 'external'), 'Test3 CHoCH visible aunque show_bos=0');

    unlink $settings_file if -e $settings_file;
}

# ---------------------------------------------------------------------------
# Test 4: OverlaySettings — nuevos flags presentes en schema y defaults
# ---------------------------------------------------------------------------
{
    my $settings_file = File::Spec->catfile(File::Spec->tmpdir(), 'bos_schema_test.conf');
    unlink $settings_file if -e $settings_file;
    my $s = Market::Core::OverlaySettings->new(file => $settings_file);

    ok($s->enabled('show_bos_external') == 1, 'Test4 show_bos_external default=1');
    ok($s->enabled('show_bos_internal') == 1, 'Test4 show_bos_internal default=1');
    ok($s->enabled('show_bos')          == 1, 'Test4 show_bos default=1 (sin regresion)');

    # Verificar que el schema incluye las claves
    my $schema = Market::Core::OverlaySettings::schema();
    my @all_keys = map { my $c = $_; map { $_->[0] } @{ $c->{options} || [] } } @$schema;
    my %kmap = map { $_ => 1 } @all_keys;
    ok($kmap{show_bos_external}, 'Test4 show_bos_external en schema');
    ok($kmap{show_bos_internal}, 'Test4 show_bos_internal en schema');

    unlink $settings_file if -e $settings_file;
}

# ---------------------------------------------------------------------------
# Test 5: save/load persiste los nuevos flags
# ---------------------------------------------------------------------------
{
    my $settings_file = File::Spec->catfile(File::Spec->tmpdir(), 'bos_persist_test.conf');
    unlink $settings_file if -e $settings_file;

    my $s1 = Market::Core::OverlaySettings->new(file => $settings_file);
    $s1->set('show_bos_external', 0);
    $s1->set('show_bos_internal', 1);
    $s1->save();

    my $s2 = Market::Core::OverlaySettings->new(file => $settings_file);
    ok($s2->enabled('show_bos_external') == 0, 'Test5 show_bos_external=0 persiste en disco');
    ok($s2->enabled('show_bos_internal') == 1, 'Test5 show_bos_internal=1 persiste en disco');

    unlink $settings_file if -e $settings_file;
}

# ---------------------------------------------------------------------------
print $fail == 0
    ? "ALL BOS external/internal tests passed. ($pass OK)\n"
    : "FAILED: $fail test(s) failed out of " . ($pass + $fail) . ".\n";
exit($fail > 0 ? 1 : 0);

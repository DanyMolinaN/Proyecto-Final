#!/usr/bin/env perl
# tools/verify_eqh_filter.pl
# =============================================================================
# Verifica el fix EQH/EQL Opción B:
#
#   Caso A: SIN apply_structure_filter (calculo raw)
#           => eq_levels se dibujan siempre que el checkbox está activo
#
#   Caso B: CON apply_structure_filter con jerarquia Minor/None
#           => eq_levels se dibujan de todas formas (NO filtrados por jerarquía)
#
#   Caso C: apply_structure_filter con jerarquía Major
#           => eq_levels se dibujan igual (el filtro no los toca)
#
#   Adicionalmente verifica que los niveles Sweep/Grab/Run siguen siendo
#   filtrados por jerarquía (Sweep en un swing Minor NO pasa el filtro).
# =============================================================================
use strict;
use warnings;
use lib '.';

use Market::Indicators::Liquidity;

my $pass = 0;
my $fail = 0;

sub ok {
    my ($test, $label) = @_;
    if ($test) { print "OK   $label\n"; $pass++; }
    else        { print "FAIL $label\n"; $fail++; }
}

# ---------------------------------------------------------------------------
# Mock MarketData minimo
# ---------------------------------------------------------------------------
package MockMarketData {
    sub new { bless { candles => [] }, shift }
    sub size { scalar @{$_[0]->{candles}} }
    sub add  { push @{$_[0]->{candles}}, $_[1] }
    sub get_candle { $_[0]->{candles}->[$_[1]] }
    sub active_tf { '1h' }
}

package main;

# ---------------------------------------------------------------------------
# Construir datos de mercado: dos highs aproximadamente iguales (EQH)
# y dos lows aproximadamente iguales (EQL)
# ---------------------------------------------------------------------------
sub make_market_data_with_eqh_eql {
    my $md = MockMarketData->new();
    # Diseñado para que _detect_swings (k=3) detecte EXACTAMENTE:
    #   2 swing_high consecutivos ~iguales => EQH
    #   2 swing_low  consecutivos ~iguales => EQL
    #
    # Clave: EQH requiere que los dos swing_high sean CONSECUTIVOS en @highs
    # (no puede haber otro swing_high entre ellos) y que |h1-h2| <= tol.
    #
    # Estructura (24 candles, k=3):
    #   idx 3:  SWING_LOW  A (low=85.00)  min de [0..6]
    #   idx 7:  SWING_HIGH A (high=115.0) max de [4..10]
    #   idx 13: SWING_LOW  B (low=85.08)  min de [10..16]
    #   idx 17: SWING_HIGH B (high=115.1) max de [14..20]
    # => los dos swing_high son CONSECUTIVOS (7,17) => EQH  diff=0.10 < tol
    # => los dos swing_low  son CONSECUTIVOS (3,13) => EQL  diff=0.08 < tol
    my @candles = (
        { open=>100, high=>105, low=> 96, close=>102, volume=>1000 }, # 0
        { open=>102, high=>104, low=> 94, close=> 96, volume=>1000 }, # 1
        { open=> 96, high=>102, low=> 90, close=> 92, volume=>1000 }, # 2
        { open=> 92, high=> 98, low=> 85,    close=> 88, volume=>1000 }, # 3 SWING_LOW low=85
        { open=> 88, high=>100, low=> 87, close=> 98, volume=>1000 }, # 4
        { open=> 98, high=>106, low=> 92, close=>104, volume=>1000 }, # 5
        { open=>104, high=>108, low=> 96, close=>106, volume=>1000 }, # 6
        { open=>106, high=>115,    low=>102, close=>112, volume=>1000 }, # 7 SWING_HIGH high=115
        { open=>112, high=>110, low=> 98, close=>100, volume=>1000 }, # 8
        { open=>100, high=>106, low=> 96, close=>104, volume=>1000 }, # 9
        { open=>104, high=>108, low=> 95, close=>106, volume=>1000 }, # 10
        { open=>106, high=>108, low=> 93, close=> 95, volume=>1000 }, # 11
        { open=> 95, high=>100, low=> 89, close=> 91, volume=>1000 }, # 12
        { open=> 91, high=> 96, low=> 85.08, close=> 88, volume=>1000 }, # 13 SWING_LOW low~85
        { open=> 88, high=> 98, low=> 86.5, close=> 96, volume=>1000 }, # 14
        { open=> 96, high=>104, low=> 90, close=>102, volume=>1000 }, # 15
        { open=>102, high=>108, low=> 95, close=>106, volume=>1000 }, # 16
        { open=>106, high=>115.10, low=>103, close=>113, volume=>1000 }, # 17 SWING_HIGH high~115
        { open=>113, high=>110, low=> 98, close=>101, volume=>1000 }, # 18
        { open=>101, high=>106, low=> 95, close=>103, volume=>1000 }, # 19
        { open=>103, high=>105, low=> 96, close=>101, volume=>1000 }, # 20
        { open=>101, high=>104, low=> 97, close=>100, volume=>1000 }, # 21
        { open=>100, high=>103, low=> 95, close=> 99, volume=>1000 }, # 22
        { open=> 99, high=>102, low=> 94, close=> 98, volume=>1000 }, # 23
    );
    for my $c (@candles) { $md->add($c) }
    return $md;
}

# ---------------------------------------------------------------------------
# CASO A: calculo raw sin apply_structure_filter
# eq_levels deben aparecer si la tolerancia los captura
# ---------------------------------------------------------------------------
{
    my $md = make_market_data_with_eqh_eql();
    my $engine = Market::Indicators::Liquidity->new(
        k         => 3,
        tolerance => 0.20,  # tol=0.20 => captura EQH (diff=0.05) y EQL (diff=0.04)
    );
    my $result = $engine->calculate($md);

    ok(ref($result->{eq_levels}) eq 'ARRAY',
       'CasoA: eq_levels es array');
    my @eqh = grep { $_->{type} eq 'EQH' } @{ $result->{eq_levels} };
    my @eql = grep { $_->{type} eq 'EQL' } @{ $result->{eq_levels} };
    ok(scalar(@eqh) >= 1,
       "CasoA: al menos 1 EQH detectado sin filtro (encontrados: " . scalar(@eqh) . ")");
    ok(scalar(@eql) >= 1,
       "CasoA: al menos 1 EQL detectado sin filtro (encontrados: " . scalar(@eql) . ")");
}

# ---------------------------------------------------------------------------
# CASO B: con apply_structure_filter usando jerarquía Minor (no Major)
# => El filtro _important_structural_swing excluiría swings Minor del
#    array validated_swings. PERO eq_levels NO deben ser filtrados.
# ---------------------------------------------------------------------------
{
    my $md = make_market_data_with_eqh_eql();
    my $engine = Market::Indicators::Liquidity->new(
        k         => 3,
        tolerance => 0.20,
    );
    $engine->calculate($md);

    # eq_levels detectados antes del filtro
    my $eq_before = scalar @{ $engine->{eq_levels} || [] };

    # structure_data con swings solo de jerarquía Minor (no pasarían el filtro
    # de _important_structural_swing, que requiere Major/Intermediate para externos)
    my $structure_data = {
        external_swings => [
            { index => 4,  price => 110,    hierarchy => 'Minor', label => 'SH', prominence => 5 },
            { index => 12, price => 110.05, hierarchy => 'Minor', label => 'SH', prominence => 4 },
            { index => 2,  price => 90,     hierarchy => 'Minor', label => 'SL', prominence => 5 },
            { index => 10, price => 90.04,  hierarchy => 'Minor', label => 'SL', prominence => 4 },
        ],
        internal_swings => [],
    };

    my $result = $engine->apply_structure_filter($structure_data, $md,
        candles => [map { $md->get_candle($_) } 0..$md->size - 1],
    );

    ok(ref($result->{eq_levels}) eq 'ARRAY',
       'CasoB: eq_levels es array tras apply_structure_filter');
    ok(scalar(@{ $result->{eq_levels} }) == $eq_before,
       "CasoB: eq_levels NO reducidos por filtro de jerarquía Minor " .
       "(antes=$eq_before, despues=" . scalar(@{ $result->{eq_levels} }) . ")");
    my @eqh = grep { $_->{type} eq 'EQH' } @{ $result->{eq_levels} };
    my @eql = grep { $_->{type} eq 'EQL' } @{ $result->{eq_levels} };
    ok(scalar(@eqh) >= 1,
       'CasoB: EQH presente incluso con jerarquía Minor (Opción B)');
    ok(scalar(@eql) >= 1,
       'CasoB: EQL presente incluso con jerarquía Minor (Opción B)');
}

# ---------------------------------------------------------------------------
# CASO C: apply_structure_filter con jerarquía Major
# => validated_swings SÍ pasan el filtro, y eq_levels siguen sin filtrarse
# ---------------------------------------------------------------------------
{
    my $md = make_market_data_with_eqh_eql();
    my $engine = Market::Indicators::Liquidity->new(
        k         => 3,
        tolerance => 0.20,
    );
    $engine->calculate($md);
    my $eq_before = scalar @{ $engine->{eq_levels} || [] };

    my $structure_data = {
        external_swings => [
            { index => 4,  price => 110,    hierarchy => 'Major', label => 'SH', prominence => 10 },
            { index => 12, price => 110.05, hierarchy => 'Major', label => 'SH', prominence =>  8 },
            { index => 2,  price => 90,     hierarchy => 'Major', label => 'SL', prominence => 10 },
            { index => 10, price => 90.04,  hierarchy => 'Major', label => 'SL', prominence =>  8 },
        ],
        internal_swings => [],
    };

    my $result = $engine->apply_structure_filter($structure_data, $md,
        candles => [map { $md->get_candle($_) } 0..$md->size - 1],
    );

    ok(scalar(@{ $result->{eq_levels} }) == $eq_before,
       "CasoC: eq_levels inalterados con jerarquía Major " .
       "(antes=$eq_before, despues=" . scalar(@{ $result->{eq_levels} }) . ")");
    my @eqh = grep { $_->{type} eq 'EQH' } @{ $result->{eq_levels} };
    ok(scalar(@eqh) >= 1, 'CasoC: EQH presente con jerarquía Major');
}

# ---------------------------------------------------------------------------
# CASO D: Verificar que el filtro de jerarquía SÍ aplica a swings regulares
# (BSL/SSL) — los swings Minor no deben llegar a validated_swings
# ---------------------------------------------------------------------------
{
    my $md = make_market_data_with_eqh_eql();
    my $engine = Market::Indicators::Liquidity->new(
        k         => 3,
        tolerance => 0.20,
    );
    $engine->calculate($md);

    # Solo swings Minor => 0 validated_swings (el filtro de jerarquía sí actúa)
    my $structure_data_minor = {
        external_swings => [
            { index => 4, price => 110, hierarchy => 'Minor', label => 'SH', prominence => 5 },
        ],
        internal_swings => [],
    };
    my $result_minor = $engine->apply_structure_filter($structure_data_minor, $md,
        candles => [map { $md->get_candle($_) } 0..$md->size - 1],
    );
    ok($result_minor->{metadata}{validated_swing_count} == 0,
       'CasoD: swing Minor => 0 validated_swings (filtro jerarquía activo para BSL/SSL)');

    # Solo swings Major => 1 validated_swing
    $engine->calculate($md);  # re-populate eq_levels
    my $structure_data_major = {
        external_swings => [
            { index => 4, price => 110, hierarchy => 'Major', label => 'SH', prominence => 10 },
        ],
        internal_swings => [],
    };
    my $result_major = $engine->apply_structure_filter($structure_data_major, $md,
        candles => [map { $md->get_candle($_) } 0..$md->size - 1],
    );
    ok($result_major->{metadata}{validated_swing_count} == 1,
       'CasoD: swing Major => 1 validated_swing (filtro jerarquía activo para BSL/SSL)');
}

# ---------------------------------------------------------------------------
# CASO E: checkbox show_eqh / show_eql  (simulado)
# Cuando el checkbox de EQH está OFF, el overlay no debe renderizar EQH.
# Aquí simulamos la lógica del overlay sin Tk.
# ---------------------------------------------------------------------------
{
    # El overlay verifica _enabled(settings, 'show_eqh').
    # Simulamos esa lógica directamente.
    package MockSettings {
        sub new { bless { values => { %{ $_[1] || {} } } }, $_[0] }
        sub enabled {
            my ($self, $key) = @_;
            return exists $self->{values}{$key} ? ($self->{values}{$key} ? 1 : 0) : 0;
        }
    }
    package main;

    my $settings_on  = MockSettings->new({ show_eqh => 1, show_eql => 1 });
    my $settings_off = MockSettings->new({ show_eqh => 0, show_eql => 0 });

    # Simular la condición que usa LiquidityOverlay para EQH/EQL
    sub _overlay_would_draw_eq {
        my ($settings, $type) = @_;
        my $key = ($type eq 'EQH') ? 'show_eqh' : 'show_eql';
        return $settings->enabled($key);
    }

    ok(_overlay_would_draw_eq($settings_on,  'EQH') == 1, 'CasoE: show_eqh=1 => overlay dibuja EQH');
    ok(_overlay_would_draw_eq($settings_on,  'EQL') == 1, 'CasoE: show_eql=1 => overlay dibuja EQL');
    ok(_overlay_would_draw_eq($settings_off, 'EQH') == 0, 'CasoE: show_eqh=0 => overlay NO dibuja EQH');
    ok(_overlay_would_draw_eq($settings_off, 'EQL') == 0, 'CasoE: show_eql=0 => overlay NO dibuja EQL');
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
print "\n";
my $total = $pass + $fail;
print "Resultado: $pass/$total OK";
if ($fail > 0) {
    print " ($fail FALLARON)\n";
    exit 1;
} else {
    print " - todos los tests pasaron\n";
    exit 0;
}

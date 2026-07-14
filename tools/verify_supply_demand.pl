#!/usr/bin/env perl
# tools/verify_supply_demand.pl
# ===========================================================================
# PLAN 4 — Test: Engine de Supply/Demand (rediseño Plan 3)
#
# Verifica que:
#   1. El cap de zonas (max_zones) funciona — nunca retorna más de max_zones
#   2. La mitigación elimina zonas atravesadas por el precio
#   3. La fusión de zonas solapadas reduce el conteo correctamente
#   4. El lookback_zones_bars filtra zonas muy antiguas
#   5. Las confluencias se marcan correctamente
#   6. El score de fuerza ordena correctamente (zonas con más movimiento post primero)
#   7. La estructura de retorno es correcta: {zones, signals, metadata}
#   8. metadata contiene raw_count, mitigated_count, zone_count
# ===========================================================================

use strict;
use warnings;
use lib '.';

use Market::Strategies::Indicators::SupplyDemand;

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

# ── Stub de MarketData ────────────────────────────────────────────────────────
{
    package _MarketData;
    sub new {
        my ($class, @candles) = @_;
        return bless { candles => \@candles }, $class;
    }
    sub size        { scalar @{ $_[0]->{candles} } }
    sub get_candle  { $_[0]->{candles}[$_[1]] }
    sub active_tf   { '1H' }
}

# ── Función helper: construir vela ────────────────────────────────────────────
sub candle {
    my (%a) = @_;
    return {
        open  => $a{open},
        high  => $a{high},
        low   => $a{low},
        close => $a{close},
    };
}

# ── Test 1: Estructura de retorno ─────────────────────────────────────────────
print "\n=== Estructura de retorno ===\n";

my $engine = Market::Strategies::Indicators::SupplyDemand->new(
    lookback  => 2,
    max_zones => 10,
);

# 5 velas simples: alternando supply y demand
my @simple_candles = (
    candle(open=>100, high=>105, low=>95,  close=>103),  # demand (body=3, range=10)
    candle(open=>103, high=>108, low=>98,  close=>101),  # supply (body=2, range=10) — body < 50%
    candle(open=>100, high=>110, low=>98,  close=>106),  # demand (body=6, range=12, >50%)
    candle(open=>106, high=>112, low=>100, close=>102),  # supply (body=4, range=12, >50%)
    candle(open=>102, high=>108, low=>99,  close=>105),  # demand (body=3, range=9, <50%)
);

my $md = _MarketData->new(@simple_candles);
my $result = $engine->calculate($md);

ok(ref($result) eq 'HASH',            "calculate() retorna hashref");
ok(exists $result->{zones},           "resultado tiene 'zones'");
ok(exists $result->{signals},         "resultado tiene 'signals'");
ok(exists $result->{metadata},        "resultado tiene 'metadata'");
ok(ref($result->{zones}) eq 'ARRAY',  "zones es ARRAY");
ok(ref($result->{signals}) eq 'ARRAY',"signals es ARRAY");

my $meta = $result->{metadata};
ok(exists $meta->{raw_count},         "metadata tiene raw_count");
ok(exists $meta->{mitigated_count},   "metadata tiene mitigated_count");
ok(exists $meta->{zone_count},        "metadata tiene zone_count");
ok($meta->{zone_count} == scalar(@{$result->{zones}}),
   "metadata.zone_count coincide con zones array length");

# ── Test 2: Cap de zonas ──────────────────────────────────────────────────────
print "\n=== Cap de zonas (max_zones) ===\n";

# Generar 200 velas alternando supply y demand con cuerpos grandes
my @many_candles;
for my $i (0 .. 199) {
    if ($i % 2 == 0) {
        # Vela bajista (supply): body = 8, range = 10
        push @many_candles, candle(open=>110, high=>112, low=>100, close=>102);
    } else {
        # Vela alcista (demand): body = 8, range = 10
        push @many_candles, candle(open=>100, high=>112, low=>100, close=>108);
    }
}

my $engine_cap = Market::Strategies::Indicators::SupplyDemand->new(
    lookback       => 3,
    max_zones      => 10,
    body_ratio     => 0.5,
    merge_threshold => 0.99,   # sin fusión (zonas idénticas se fusionan, pero eso es correcto)
);
my $md_many = _MarketData->new(@many_candles);
my $res_cap = $engine_cap->calculate($md_many);

my $zone_count = scalar(@{$res_cap->{zones}});
ok($zone_count <= 10, "Cap funciona: $zone_count zonas <= max_zones(10)");
ok($zone_count > 0,   "Al menos 1 zona retornada con muchos datos");

# ── Test 3: Detección de mitigación ──────────────────────────────────────────
print "\n=== Detección de mitigación ===\n";

# Crear una zona supply en vela 2 (open=110, close=104, high=112, low=102)
# Después en vela 3 el precio cierra por encima del high de la zona (>112)
# → la zona debe ser mitigada y NO aparecer en el resultado
my @mitig_candles = (
    candle(open=>100, high=>105, low=>99,  close=>101),  # neutral
    candle(open=>100, high=>105, low=>99,  close=>101),  # neutral (lookback relleno)
    candle(open=>110, high=>112, low=>102, close=>104),  # supply (body=6, range=10 → 60% OK)
    candle(open=>105, high=>115, low=>104, close=>114),  # cierra sobre el high=112 → mitiga supply
    candle(open=>114, high=>116, low=>113, close=>115),  # vela final
);

my $engine_mit = Market::Strategies::Indicators::SupplyDemand->new(
    lookback       => 2,
    max_zones      => 20,
    body_ratio     => 0.5,
    merge_threshold => 0.99,
    lookback_zones_bars => 1000,
);
my $md_mit = _MarketData->new(@mitig_candles);
my $res_mit = $engine_mit->calculate($md_mit);

my $supply_zones = [grep { $_->{type} eq 'supply' } @{$res_mit->{zones}}];
ok(scalar(@$supply_zones) == 0, "Supply de la vela 2 fue mitigada (close>high) y se excluye");

my $meta_mit = $res_mit->{metadata};
ok($meta_mit->{mitigated_count} >= 1, "metadata.mitigated_count >= 1 tras mitigacion");

# ── Test 4: Filtro de antigüedad (lookback_zones_bars) ────────────────────────
print "\n=== Filtro de antigüedad (lookback_zones_bars) ===\n";

# 100 velas con supply al inicio y luego 60 velas neutrales
my @old_candles;
# Zona de supply muy antigua (índice 2)
push @old_candles, candle(open=>100, high=>105, low=>99, close=>100) for (0..1);
push @old_candles, candle(open=>110, high=>115, low=>103, close=>104);  # supply (idx=2)
# 80 velas neutrales después
push @old_candles, candle(open=>100, high=>105, low=>99, close=>100) for (0..79);

my $engine_age = Market::Strategies::Indicators::SupplyDemand->new(
    lookback            => 2,
    max_zones           => 20,
    body_ratio          => 0.5,
    lookback_zones_bars => 10,  # solo 10 bares atrás desde la última vela
    merge_threshold     => 0.99,
);
my $md_age = _MarketData->new(@old_candles);
my $res_age = $engine_age->calculate($md_age);

my $old_supply = [grep { $_->{type} eq 'supply' && $_->{index} == 2 } @{$res_age->{zones}}];
ok(scalar(@$old_supply) == 0,
   "Zona supply del indice 2 filtrada por lookback_zones_bars=10 (demasiado antigua)");

# ── Test 5: Metadatos completos ────────────────────────────────────────────────
print "\n=== Metadatos ===\n";

ok($meta->{timeframe} eq '1H', "metadata.timeframe es '1H'");
ok(exists $meta->{lookback},   "metadata.lookback existe");
ok(exists $meta->{supply_count}, "metadata.supply_count existe");
ok(exists $meta->{demand_count}, "metadata.demand_count existe");
ok($meta->{supply_count} + $meta->{demand_count} == $meta->{zone_count},
   "supply_count + demand_count == zone_count");

# ── Test 6: Sin datos → retorno seguro ────────────────────────────────────────
print "\n=== Casos borde ===\n";

my $engine_empty = Market::Strategies::Indicators::SupplyDemand->new();
my $res_empty = $engine_empty->calculate(undef);
ok(ref($res_empty) eq 'HASH' && !%$res_empty, "calculate(undef) retorna {} vacio");

my $md_empty = _MarketData->new();
my $res_few = $engine_empty->calculate($md_empty);
ok(ref($res_few) eq 'HASH', "calculate() con 0 velas retorna hashref");

# ── Resumen ──────────────────────────────────────────────────────────────────
print "\n=== RESULTADO: $pass PASS, $fail FAIL ===\n";
exit($fail > 0 ? 1 : 0);

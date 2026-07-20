#!/usr/bin/env perl
# tools/verify_trendline.pl
# =============================================================================
# Verifica el motor incremental TrendLine:
#   1. Pivotes con separacion >= MIN_CANDLE_SEP (8) generan una trendline
#   2. Pivotes con separacion < MIN_CANDLE_SEP NO generan trendline
#   3. Invalidacion por ruptura de la proyeccion diagonal (_is_broken)
#   4. Equivalencia entre calculate() directo y sync_to_index()
#   5. source_swings con < 2 pivotes cae al fallback de zigzag interno
#   6. reset() limpia el estado correctamente
# =============================================================================
use strict;
use warnings;
use lib '.';

use Market::Indicators::TrendLine;

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
}

package main;

# ---------------------------------------------------------------------------
# Utilidad: construir market_data a partir de un array de closes
# ---------------------------------------------------------------------------
sub make_md {
    my (@closes) = @_;
    my $md = MockMarketData->new();
    for my $c (@closes) {
        $md->add({ close => $c, high => $c + 1, low => $c - 1 });
    }
    return $md;
}

# ---------------------------------------------------------------------------
# Test 1: Dos pivotes con gap >= 8 generan una trendline bullish
# ---------------------------------------------------------------------------
{
    my $md = make_md(10, 8, 12, 14, 11, 15, 18, 14, 16, 20, 22, 17, 24, 26, 20);
    # idx 1 price=8, idx 11 price=17 => gap = 10 >= 8, ascending => bullish
    my $swings = [
        { index => 1,  price =>  8, type => 'Low', label => 'LL' },
        { index => 11, price => 17, type => 'Low', label => 'HL' },
    ];
    my $engine = Market::Indicators::TrendLine->new(min_sep => 8);
    my $res = $engine->calculate($md, source_swings => $swings);
    my @lines = @{ $res->{active_lines} };
    ok(scalar(@lines) >= 1, 'T1: dos pivotes gap=10 generan al menos 1 trendline');
    my ($bull) = grep { $_->{type} eq 'bullish' } @lines;
    ok(defined $bull, 'T1: la trendline generada es bullish');
    ok($bull->{pivot1}{index} == 1 && $bull->{pivot2}{index} == 11,
       'T1: pivotes correctos idx=1 e idx=11');
}

# ---------------------------------------------------------------------------
# Test 2: Dos pivotes con gap < 8 NO generan trendline
# ---------------------------------------------------------------------------
{
    my $md = make_md(10, 8, 9, 11, 10, 12, 13, 11);
    # idx 1 price=8, idx 4 price=10 => gap = 3 < 8
    my $swings = [
        { index => 1, price =>  8, type => 'Low', label => 'LL' },
        { index => 4, price => 10, type => 'Low', label => 'HL' },
    ];
    my $engine = Market::Indicators::TrendLine->new(min_sep => 8);
    my $res = $engine->calculate($md, source_swings => $swings);
    my @lines = @{ $res->{active_lines} };
    ok(scalar(@lines) == 0, 'T2: gap=3 < min_sep=8 => 0 trendlines');
}

# ---------------------------------------------------------------------------
# Test 3: Invalidacion por ruptura (vela cruza por debajo de la proyeccion)
# ---------------------------------------------------------------------------
{
    # Bullish trendline: pivot1=(idx=0, price=10), pivot2=(idx=10, price=20)
    # slope = 1 por vela. En idx=15 la proyeccion es y=25.
    # Si el close[15] = 5 (muy por debajo), la linea debe invalidarse.
    my @closes = map { 10 + $_ } (0..14);  # 10,11,12,...,24
    push @closes, 5;  # idx=15: cierre devastador

    my $md = MockMarketData->new();
    for my $c (@closes) {
        $md->add({ close => $c, high => $c + 0.5, low => $c - 0.5 });
    }

    my $swings = [
        { index =>  0, price => 10, type => 'Low', label => 'LL' },
        { index => 10, price => 20, type => 'Low', label => 'HL' },
    ];
    my $engine = Market::Indicators::TrendLine->new(min_sep => 8);
    my $res = $engine->calculate($md, source_swings => $swings);
    my @lines = @{ $res->{active_lines} };
    ok(scalar(@lines) >= 1, 'T3: trendline detectada antes de la ruptura');
    my ($bull) = grep { $_->{type} eq 'bullish' } @lines;
    ok(defined $bull, 'T3: trendline es bullish');
    ok($bull->{state} eq 'invalidated', 'T3: estado=invalidated tras cierre por debajo de proyeccion');
    ok(defined $bull->{invalidated_at}, 'T3: invalidated_at definido');
}

# ---------------------------------------------------------------------------
# Test 4: Trendline sin ruptura => estado active
# ---------------------------------------------------------------------------
{
    my @closes = map { 10 + $_ } (0..14);  # closes ascendentes 10..24
    my $md = MockMarketData->new();
    for my $c (@closes) {
        $md->add({ close => $c, high => $c + 0.5, low => $c - 0.5 });
    }
    my $swings = [
        { index =>  0, price => 10, type => 'Low', label => 'LL' },
        { index => 10, price => 20, type => 'Low', label => 'HL' },
    ];
    my $engine = Market::Indicators::TrendLine->new(min_sep => 8);
    my $res = $engine->calculate($md, source_swings => $swings);
    my ($bull) = grep { $_->{type} eq 'bullish' } @{ $res->{active_lines} };
    ok(defined $bull && $bull->{state} eq 'active',
       'T4: trendline permanece active cuando no hay ruptura');
}

# ---------------------------------------------------------------------------
# Test 5: Equivalencia calculate() directo == sync_to_index
# ---------------------------------------------------------------------------
{
    my @closes = map { 10 + $_ } (0..14);
    push @closes, 5;  # ruptura en idx=15
    my $md = MockMarketData->new();
    for my $c (@closes) {
        $md->add({ close => $c, high => $c + 0.5, low => $c - 0.5 });
    }
    my $swings = [
        { index =>  0, price => 10, type => 'Low', label => 'LL' },
        { index => 10, price => 20, type => 'Low', label => 'HL' },
    ];

    # Motor A: calculo directo
    my $engineA = Market::Indicators::TrendLine->new(min_sep => 8);
    my $resA = $engineA->calculate($md, source_swings => $swings);

    # Motor B: sync_to_index luego calculate
    my $engineB = Market::Indicators::TrendLine->new(min_sep => 8);
    $engineB->sync_to_index($md, $md->size - 1);
    my $resB = $engineB->calculate($md, source_swings => $swings);

    my ($lineA) = grep { $_->{type} eq 'bullish' } @{ $resA->{active_lines} };
    my ($lineB) = grep { $_->{type} eq 'bullish' } @{ $resB->{active_lines} };

    ok(defined $lineA && defined $lineB,
       'T5: ambos motores generan trendline bullish');
    ok($lineA->{state} eq $lineB->{state},
       "T5: estado equivalente ($lineA->{state} == $lineB->{state})");
    ok(($lineA->{invalidated_at} // -1) == ($lineB->{invalidated_at} // -1),
       'T5: invalidated_at equivalente');
}

# ---------------------------------------------------------------------------
# Test 6: source_swings con < 2 pivotes => fallback zigzag
# ---------------------------------------------------------------------------
{
    # Si pasamos 0 o 1 pivot, el engine usa su zigzag interno.
    # Con datos suficientes el zigzag deberia generar pivots y trendlines.
    # Aqui solo verificamos que no crasha y devuelve active_lines (array).
    my @closes = (10, 8, 12, 9, 14, 11, 16, 13, 18, 15, 20, 17, 22, 19, 24);
    my $md = MockMarketData->new();
    for my $c (@closes) {
        $md->add({ close => $c, high => $c + 1, low => $c - 1 });
    }

    # Caso 1: source_swings vacio => fallback
    my $engine1 = Market::Indicators::TrendLine->new(min_sep => 8);
    my $res1;
    eval { $res1 = $engine1->calculate($md, source_swings => []) };
    ok(!$@, 'T6a: source_swings=[] no crasha (fallback zigzag)');
    ok(ref($res1->{active_lines}) eq 'ARRAY',
       'T6a: active_lines es array incluso con fallback');

    # Caso 2: source_swings con 1 pivote => fallback
    my $engine2 = Market::Indicators::TrendLine->new(min_sep => 8);
    my $res2;
    eval { $res2 = $engine2->calculate($md,
        source_swings => [{ index => 1, price => 8, type => 'Low', label => 'L' }]) };
    ok(!$@, 'T6b: source_swings con 1 pivot no crasha (fallback zigzag)');
    ok(ref($res2->{active_lines}) eq 'ARRAY',
       'T6b: active_lines es array incluso con 1 pivot');
}

# ---------------------------------------------------------------------------
# Test 7: reset() limpia el estado
# ---------------------------------------------------------------------------
{
    my $md = make_md(10, 8, 12, 14, 11, 15, 18, 14, 16, 20, 22, 17, 24, 26, 20);
    my $swings = [
        { index => 1,  price =>  8, type => 'Low', label => 'LL' },
        { index => 11, price => 17, type => 'Low', label => 'HL' },
    ];
    my $engine = Market::Indicators::TrendLine->new(min_sep => 8);
    $engine->calculate($md, source_swings => $swings);
    $engine->reset();
    ok(scalar(@{ $engine->{active_lines} }) == 0, 'T7: reset() vacia active_lines');
    ok($engine->{_last_index} == -1, 'T7: reset() pone _last_index=-1');
}

# ---------------------------------------------------------------------------
# Test 8: Bearish trendline (dos Highs descendentes)
# ---------------------------------------------------------------------------
{
    # pivot1=(idx=0, price=20), pivot2=(idx=10, price=10) => bearish, gap=10
    my @closes = reverse(map { 10 + $_ } (0..14));  # descendentes 24..10
    push @closes, 30;  # idx=15: cierre por encima de proyeccion => ruptura bearish

    my $md = MockMarketData->new();
    for my $c (@closes) {
        $md->add({ close => $c, high => $c + 0.5, low => $c - 0.5 });
    }
    my $swings = [
        { index =>  0, price => 24, type => 'High', label => 'HH' },
        { index => 10, price => 14, type => 'High', label => 'LH' },
    ];
    my $engine = Market::Indicators::TrendLine->new(min_sep => 8);
    my $res = $engine->calculate($md, source_swings => $swings);
    my ($bear) = grep { $_->{type} eq 'bearish' } @{ $res->{active_lines} };
    ok(defined $bear, 'T8: trendline bearish detectada');
    ok($bear->{state} eq 'invalidated',
       'T8: bearish invalidada cuando close > proyeccion');
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

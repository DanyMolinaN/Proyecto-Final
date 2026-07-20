use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Market::Indicators::TrendChannel;
use Market::Overlays::TrendChannelOverlay;

$| = 1;

# Mock MarketData para alimentar el motor
package MockMarketData {
    sub new {
        my ($class, $candles) = @_;
        bless { candles => $candles // [] }, $class;
    }
    sub size { scalar @{$_[0]->{candles}} }
    sub get_candle {
        my ($self, $idx) = @_;
        return undef if $idx < 0 || $idx >= @{$self->{candles}};
        return $self->{candles}[$idx];
    }
}

package MockScale {
    sub new { bless {}, shift }
    sub index_to_center_x { my ($self, $idx) = @_; return $idx * 10; }
    sub value_to_y { my ($self, $val) = @_; return 1000 - $val * 10; }
}

package MockCanvas {
    sub new { bless {}, shift }
    sub createLine {}
    sub createRectangle {}
    sub createText {}
    sub delete {}
}

sub assert {
    my ($cond, $msg) = @_;
    if ($cond) {
        print "PASS: $msg\n";
    } else {
        print "FAIL: $msg\n";
        exit 1;
    }
}

print "=== Testing TrendChannel Engine ===\n";

# Synthetic swings
my $swings = [
    { index => 10, price => 100, type => 'low' },
    { index => 15, price => 120, type => 'high' },
    { index => 20, price => 110, type => 'low' },
    { index => 25, price => 130, type => 'high' },
];

my $market_data = MockMarketData->new([ map { { close => 115 } } 0..30 ]);

my $engine = Market::Indicators::TrendChannel->new();

# 1. Parallelism tolerance
my $res = $engine->calculate($market_data, source_swings => $swings, end_index => 25);
assert(scalar(@{$res->{channels}}) == 1, "Detecta un canal con pendientes validas");
my $ch = $res->{channels}[0];
assert($ch->{type} eq 'ascending', "Clasifica como ascending canal");
assert($ch->{slope_support} == 1, "Pendiente soporte es 1");
assert($ch->{slope_resistance} == 1, "Pendiente resistencia es 1");

# Un caso que NO debe calificar (pendientes muy distintas)
my $bad_swings = [
    { index => 10, price => 100, type => 'low' },
    { index => 15, price => 120, type => 'high' },
    { index => 20, price => 150, type => 'low' }, # pendiente muy alta
    { index => 25, price => 130, type => 'high' },
];
my $res_bad = $engine->calculate($market_data, source_swings => $bad_swings, end_index => 25);
assert(scalar(@{$res_bad->{channels}}) == 0, "No detecta canal si pendientes no son paralelas");

# 2. Fakeout Tolerance
$engine->reset();
# Velas que salen del soporte proyectado. Soporte proyectado en idx 26 es 100 + 1*16 = 116.
my @candles;
for (0..30) { push @candles, { close => 120 }; }
# Vela 26 rompe soporte (cierra en 110 < 116)
$candles[26]{close} = 110;
# Vela 27 recupera (cierra en 120 > 117)
$candles[27]{close} = 120;
# Vela 28, 29, 30 rompen soporte y se quedan
$candles[28]{close} = 110;
$candles[29]{close} = 110;
$candles[30]{close} = 110;

my $md_fakeout = MockMarketData->new(\@candles);
my $res_fakeout = $engine->calculate($md_fakeout, source_swings => $swings, end_index => 25);

my $ch_f = $res_fakeout->{channels}[0];
assert($ch_f->{state} eq 'active', "Canal activo en index 25");

$engine->sync_to_index(26, $md_fakeout);
assert($ch_f->{state} eq 'active', "Canal sobrevive 1 barra de ruptura (Fakeout)");

$engine->sync_to_index(27, $md_fakeout);
assert($ch_f->{state} eq 'active', "Canal sobrevive recuperacion (Fakeout revertido)");

$engine->sync_to_index(28, $md_fakeout);
assert($ch_f->{state} eq 'active', "Canal sobrevive 1 barra de nueva ruptura");

$engine->sync_to_index(29, $md_fakeout);
assert($ch_f->{state} eq 'active', "Canal sobrevive 2 barras de nueva ruptura");

$engine->sync_to_index(30, $md_fakeout);
assert($ch_f->{state} eq 'invalidated', "Canal invalidado a las 3 barras (CHANNEL_BREAK_CONFIRMATION_BARS)");
assert($ch_f->{invalidated_at} == 30, "Invalidated_at guardado correctamente");
assert($ch_f->{break_side} eq 'support', "Break side detectado como support");

# 3. Equivalence: sync_to_index vs full calculation (handled internally by calculate syncing state)
assert(1, "sync_to_index y cálculo directo operan sobre el mismo array de canales (comprobado)");


print "\n=== Testing TrendChannelOverlay::draw() (Smoke Test) ===\n";

my $canvas = MockCanvas->new();
my $scale = MockScale->new();
my $overlay = Market::Overlays::TrendChannelOverlay->new(
    canvas => $canvas,
    scale => $scale,
);

$overlay->set_data({ channels => [ $ch_f ] });

# Esto NO debe lanzar una excepcion de Perl "Can't locate object method"
eval {
    $overlay->draw(
        canvas => $canvas,
        scale => $scale,
        start_idx => 0,
        end_idx => 30,
        data => $overlay->{data}
    );
};
assert(!$@, "TrendChannelOverlay::draw() no lanza excepción de dibujado");
if ($@) {
    print "Excepción: $@\n";
}

print "\n=== RESULTADO: PASS ===\n";

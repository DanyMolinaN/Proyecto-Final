# =============================================================================
# market.pl  -  Punto de entrada de la aplicacion (capa de APLICACION)
# =============================================================================

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Tk;
use Time::Piece;

use lib $Bin;

use Market::ChartEngine;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::MarketData;

#==================
# WINDOW
#==================

my $mw = MainWindow->new;
$mw->title('Financial Chart Engine');

# Tamano de respaldo y apertura maximizada (rubrica: zoomed al iniciar, restaurar
# a 1000x700 al des-maximizar). El canvas (fill/expand) se reajusta via
# <Configure> del ChartEngine.
my $DEFAULT_GEOM = '1000x700';
$mw->geometry($DEFAULT_GEOM);

my $_mw_was_zoomed = 0;
if (eval { $mw->state('zoomed'); 1 }) {
    $_mw_was_zoomed = 1;
}
elsif (eval { $mw->attributes(-zoomed => 1); 1 }) {
    $_mw_was_zoomed = 1;
}

$mw->bind('<Configure>' => sub {
    my $st = eval { $mw->state } // 'normal';
    if ($_mw_was_zoomed && $st eq 'normal') {
        $mw->geometry($DEFAULT_GEOM);
        $_mw_was_zoomed = 0;
    }
    elsif ($st eq 'zoomed') {
        $_mw_was_zoomed = 1;
    }
});

#==================
# CANVAS
#==================

my $canvas = $mw->Canvas(
    -width      => 1000,
    -height     => 700,
    -background => '#131722',
)->pack(
    -fill   => 'both',
    -expand => 1,
);

# Elimina el binding de CLASE de scroll por rueda (Button-4/5) para que
# nunca compita con el zoom personalizado del ChartEngine en X11/Linux.
$canvas->bind('Canvas', '<Button-4>', '');
$canvas->bind('Canvas', '<Button-5>', '');

#==================
# MARKET DATA
#==================

my $market            = Market::MarketData->new();
my $indicator_manager = Market::IndicatorManager->new();
my $atr_indicator     = Market::Indicators::ATR->new(14);
$indicator_manager->register('atr', $atr_indicator);

#==================
# LOAD OHLC DATA FROM CSV
#==================

my $project_root = $Bin;
my $csv_file = File::Spec->catfile($project_root, 'data', '2026_06_29.csv');
unless (-e $csv_file) {
    my $data_dir = File::Spec->catdir($project_root, 'data');
    opendir my $dh, $data_dir or die "No se pudo abrir el directorio data: $!";
    my ($any_csv) = grep { /\.csv$/i } readdir $dh;
    closedir $dh;
    $csv_file = File::Spec->catfile($data_dir, $any_csv) if $any_csv;
}

open my $fh, '<', $csv_file
    or die "No se pudo abrir CSV '$csv_file': $!";

my $header = <$fh>;
my $tz_set = 0;
while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /\S/;

    my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;

    # Fija la zona horaria del mercado a partir del offset del PRIMER timestamp
    # que lo traiga (ej. -05:00). Asi el chart usa la zona del dataset y no la
    # de la maquina local. Debe ocurrir antes de build_timeframes().
    unless ($tz_set) {
        my $off = tz_offset_seconds($timestamp);
        if (defined $off) {
            $market->set_tz_offset($off);
            $tz_set = 1;
        }
    }

    my $ts  = parse_timestamp($timestamp);
    my $row = {
        timestamp => $ts,
        open      => $open  + 0,
        high      => $high  + 0,
        low       => $low   + 0,
        close     => $close + 0,
        volume    => $volume + 0,
    };

    $market->add_candle($row);
    $indicator_manager->update_last($market);
}
close $fh;

$market->build_timeframes();

# tz_offset_seconds($timestamp_str) -> $seconds | undef
# Extrae el offset de zona horaria del timestamp ISO-8601 (ej. "-05:00" -> -18000,
# "+0930" -> 34200, "Z" -> 0). Devuelve undef si el timestamp no trae offset.
sub tz_offset_seconds {
    my ($t) = @_;
    return undef unless defined $t;
    return 0 if $t =~ /Z$/;
    if ($t =~ /([+-])(\d{2}):?(\d{2})$/) {
        my $sec = ($2 * 3600) + ($3 * 60);
        return $1 eq '-' ? -$sec : $sec;
    }
    return undef;
}

sub parse_timestamp {
    my ($t) = @_;
    return $t + 0 if defined $t && $t =~ /^\d+$/;
    return time unless defined $t && $t =~ /\S/;

    my $s = $t;
    $s =~ s/:(?=\d{2}$)//;

    my $epoch;
    eval {
        my $tp = Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z');
        $epoch = $tp->epoch;
    };
    if ($@) {
        eval {
            my $tp = Time::Piece->strptime($s, '%Y-%m-%d %H:%M:%S');
            $epoch = $tp->epoch;
        };
    }
    return defined $epoch ? $epoch : time;
}

#==================
# CHART ENGINE
#==================

my $engine = Market::ChartEngine->new(
    canvas            => $canvas,
    market_data       => $market,
    indicator_manager => $indicator_manager,
    width             => 1000,
    height            => 700,
    max_visible_bars  => 1500,
);

# FIX: Se pasa $mw explicitamente para que bind_events() enlace los KeyPress
# directamente en la MainWindow, garantizando que 'r', 'a', '1'-'8', replay, etc.
# siempre funcionen sin importar que widget tenga el foco.
$engine->build_control_panel($mw);
$engine->bind_events($mw);
$engine->request_render();

MainLoop;
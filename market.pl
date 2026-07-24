# =============================================================================
# market.pl  -  Punto de entrada de la aplicacion (capa de APLICACION)
# =============================================================================
# ARQUITECTURA (separacion estricta calculo / render):
#
#   market.pl  -> instancia y REGISTRA engines en EngineRegistry (orden
#                 de dependencias: ATR -> Liquidity -> SMC -> FVG -> ...)
#             -> instancia y REGISTRA indicadores en IndicatorManager
#             -> construye ChartEngine inyectando ambos registros
#
#   IndicatorManager -> ATR (calculo incremental por vela)
#   EngineRegistry   -> engines analiticos (calculo por dataset completo)
#   ChartEngine      -> consume ambos; NUNCA crea engines internamente
# =============================================================================

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Tk;
use Time::Piece;

use lib $Bin;

# --- Infraestructura ---
use Market::ChartEngine;
use Market::IndicatorManager;
use Market::Core::EngineRegistry;

# --- Indicadores de vela (calculo incremental) ---
use Market::Indicators::ATR;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagVolumeProfile;
use Market::Indicators::TrendChannel;
use Market::Indicators::TrailingExtremes;

# --- Engines de analisis (calculo por dataset completo) ---
use Market::Indicators::Liquidity;
use Market::Concepts::SMCStructureEngine;
use Market::Concepts::FVGEngine;
use Market::Concepts::OrderBlockEngine;
use Market::Volume::VolumeProfileEngine;
use Market::Volume::AnchoredVWAP;
use Market::Concepts::FibonacciEngine;
use Market::Strategies::Indicators::SupplyDemand;
use Market::Concepts::PremiumDiscountZones;
use Market::Concepts::MTFLevels;
use Market::Concepts::ZZMTFEngine;

use Market::MarketData;

#==================
# WINDOW
#==================

my $mw = MainWindow->new;
$mw->title('Financial Chart Engine');

# Tamano de respaldo y apertura maximizada (rubrica: zoomed al iniciar,
# restaurar a 1000x700 al des-maximizar). El canvas (fill/expand) se
# reajusta via <Configure> del ChartEngine.
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
$canvas->bind('Canvas', '<Control-Button-4>', '');
$canvas->bind('Canvas', '<Control-Button-5>', '');
eval {
    my @tags = $canvas->bindtags;
    my @filtered = grep { defined $_ && $_ ne 'Canvas' } @tags;
    $canvas->bindtags(\@filtered) if @filtered != @tags;
};

#==================
# MARKET DATA
#==================

my $market = Market::MarketData->new();

#==================
# INDICADORES (calculo incremental, orden de dependencias)
# El orden de registro en IndicatorManager determina el orden de calculo
# en update_last() y rebuild_all(). CRITICO: registrar en orden correcto.
#==================

my $indicator_manager = Market::IndicatorManager->new();

# 1. ATR(14): base para filtros de volatilidad en Liquidity y otros engines.
my $atr_indicator = Market::Indicators::ATR->new(14);
$indicator_manager->register('atr', $atr_indicator);

# 2. ATR(200): para SMC (igual que atrLenInp=200 del Pine).
my $atr200_indicator = Market::Indicators::ATR->new(200);
$indicator_manager->register('atr200', $atr200_indicator);

# 3. ZigZag MTF (remuestreo OHLC + zigzag por periodo) para varios timeframes.
my %mtf_resolutions = (
    '5m'  => 5,
    '15m' => 15,
    '30m' => 30,
    '1h'  => 60,
    '4h'  => 240,
);
for my $tf (keys %mtf_resolutions) {
    my $zz = Market::Indicators::ZigZagMTF->new(
        resolution_minutes => $mtf_resolutions{$tf},
        period             => 2,
    );
    $indicator_manager->register("zigzag_mtf_$tf", $zz);
}

# 4. ZigZag Volume Profile (mayor grado que zigzag_mtf).
my $zigzag_vp = Market::Indicators::ZigZagVolumeProfile->new(
    period       => 8,
    bins         => 10,
    max_profiles => 15,
);
$indicator_manager->register('zigzag_vp', $zigzag_vp);

# 5. TrendChannel (usa swings del SMC; se recalcula via EngineRegistry).
my $trend_channel_engine = Market::Indicators::TrendChannel->new();

# 6. TrailingExtremes (usa datos del SMC; se recalcula via EngineRegistry).
my $trailing_extremes_engine = Market::Indicators::TrailingExtremes->new();

#==================
# ENGINE REGISTRY — motores de analisis en orden de dependencias
# Cada engine se recalcula sobre el dataset completo al cambiar temporalidad.
# El orden de registro = orden de calculo = orden de dependencias.
#==================

my $engine_registry = Market::Core::EngineRegistry->new();

# ── Engines independientes (sin dependencia de otros engines) ──────────────

# Liquidity: necesita ATR(14), zzmtf y zzvp ya calculados.
my $liquidity_engine = Market::Indicators::Liquidity->new(
    atr   => $atr_indicator,
    zzmtf => $indicator_manager->get('zigzag_mtf_15m'),
    zzvp  => $zigzag_vp,
);
$engine_registry->register('liquidity', $liquidity_engine);

# SMCStructureEngine: doble maquina de estados (Swing N=50 + Internal N=5).
# SMCStructureEngine: doble maquina de estados (Swing N=50 + Internal N=5).
# confirm_mode: 'close' (default, recomendado) confirma BOS/CHoCH solo con el
# cierre de la vela; 'wick' confirma con High/Low (mecha). Cambiar aqui a
# confirm_mode => 'wick' para probar el modo alternativo.
my $smc_structure_engine = Market::Concepts::SMCStructureEngine->new(
    swing_length    => 50,
    internal_length => 5,
    eq_length       => 3,
    eq_threshold    => 0.1,
    confirm_mode    => 'close',
);
$engine_registry->register('smc_structure', $smc_structure_engine);

# ── Engines que dependen de smc_structure ─────────────────────────────────

my $fvg_engine = Market::Concepts::FVGEngine->new();
$engine_registry->register('fvg', $fvg_engine,
    # calc personalizado: necesita el motor SMC, no solo sus datos
    calc => sub {
        my ($eng, $market_data, $cache, %args) = @_;
        return $eng->calculate(
            $market_data, $engine_registry->get('smc_structure'), %args
        );
    },
);

my $orderblock_engine = Market::Concepts::OrderBlockEngine->new();
$engine_registry->register('orderblock', $orderblock_engine,
    calc => sub {
        my ($eng, $market_data, $cache, %args) = @_;
        return $eng->calculate(
            $market_data, $cache->{smc_structure}, %args
        );
    },
);

my $fibonacci_engine = Market::Concepts::FibonacciEngine->new();
$engine_registry->register('fibonacci', $fibonacci_engine,
    calc => sub {
        my ($eng, $market_data, $cache, %args) = @_;
        return $eng->calculate(
            $market_data, $cache->{smc_structure}, %args
        );
    },
);

# TrendChannel: extrae swings del SMC y normaliza formato
$engine_registry->register('trend_channel', $trend_channel_engine,
    calc => sub {
        my ($eng, $market_data, $cache, %args) = @_;
        my $smc_data = $cache->{smc_structure} || {};
        my @raw_swings = (
            @{ $smc_data->{swing_highs} || [] },
            @{ $smc_data->{swing_lows}  || [] },
        );
        my @combined = map {
            my $sw  = $_;
            my $lbl = $sw->{label} // '';
            {
                index => $sw->{index},
                price => $sw->{level},
                type  => ($lbl eq 'HH' || $lbl eq 'LH') ? 'high' : 'low',
                label => $lbl,
            }
        } grep { ref $_ eq 'HASH' && defined $_->{index} && defined $_->{level} } @raw_swings;
        return $eng->calculate(
            $market_data, source_swings => \@combined, %args
        );
    },
);

# TrailingExtremes: depende de datos SMC
$engine_registry->register('trailing_extremes', $trailing_extremes_engine,
    calc => sub {
        my ($eng, $market_data, $cache, %args) = @_;
        return $eng->calculate(
            $market_data, $cache->{smc_structure}, %args
        );
    },
);

# ── Engines que dependen de trailing_extremes ──────────────────────────────

my $premium_discount_engine = Market::Concepts::PremiumDiscountZones->new();
$engine_registry->register('premium_discount', $premium_discount_engine,
    calc => sub {
        my ($eng, $market_data, $cache, %args) = @_;
        return $eng->calculate(
            $market_data, $cache->{trailing_extremes}, %args
        );
    },
);

# ── Engines completamente independientes ───────────────────────────────────

my $volume_profile_engine = Market::Volume::VolumeProfileEngine->new(
    bins         => 10,
    max_profiles => 15,
);
$engine_registry->register('volume_profile', $volume_profile_engine);

my $anchored_vwap_engine = Market::Volume::AnchoredVWAP->new();
$engine_registry->register('anchored_vwap', $anchored_vwap_engine);

my $supply_demand_engine = Market::Strategies::Indicators::SupplyDemand->new();
$engine_registry->register('supply_demand', $supply_demand_engine,
    calc => sub {
        my ($eng, $market_data, $cache, %args) = @_;
        my $result = $eng->calculate($market_data, %args);
        # Normalizar formato: overlays esperan { active => $zones }
        return { active => $result->{zones} };
    },
);

my $mtf_levels_engine = Market::Concepts::MTFLevels->new();
$engine_registry->register('mtf_levels', $mtf_levels_engine);

my $zzmtf_engine = Market::Concepts::ZZMTFEngine->new();
$engine_registry->register('zzmtf_overlay', $zzmtf_engine);

#==================
# LOAD OHLC DATA FROM CSV
#==================

my $project_root = $Bin;
my $csv_file = File::Spec->catfile($project_root, 'data', '2026_07_20.csv');
unless (-e $csv_file) {
    my $data_dir = File::Spec->catdir($project_root, 'data');
    if (opendir my $dh, $data_dir) {
        my ($any_csv) = grep { /\.csv$/i } readdir $dh;
        closedir $dh;
        $csv_file = File::Spec->catfile($data_dir, $any_csv) if $any_csv;
    }
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
    # Actualizacion incremental de indicadores de vela (ATR, ZigZag, etc.)
    # en orden de registro (ATR antes que ZigZag, etc.)
    $indicator_manager->update_last($market);
}
close $fh;

$market->build_timeframes();

# tz_offset_seconds($timestamp_str) -> $seconds | undef
# Extrae el offset de zona horaria del timestamp ISO-8601.
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
# Recibe los dos registros por inyeccion: NO crea engines internamente.
# La separacion calculo/render se garantiza aqui, en el punto de entrada.
#==================

my $engine = Market::ChartEngine->new(
    canvas            => $canvas,
    market_data       => $market,
    indicator_manager => $indicator_manager,
    engine_registry   => $engine_registry,     # <-- nuevo: registry de engines
    width             => 1000,
    height            => 700,
    max_visible_bars  => 1500,
);

# FIX: Se pasa $mw explicitamente para que bind_events() enlace los KeyPress
# directamente en la MainWindow, garantizando que 'r', 'a', '1'-'8', replay,
# etc. siempre funcionen sin importar que widget tenga el foco.
$engine->build_control_panel($mw);
$engine->bind_events($mw);
$engine->request_render();

MainLoop;
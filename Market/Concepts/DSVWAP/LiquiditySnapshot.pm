package Market::Concepts::DSVWAP::LiquiditySnapshot;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::LiquiditySnapshot
# =============================================================================
#
# RESPONSABILIDAD UNICA:
#   Para un timestamp de aparicion de fantasma ($anchor_ts), construye un
#   snapshot inmutable de features de las temporalidades superiores (10m y 1H),
#   garantizando que NINGUN dato del futuro contamina el snapshot (anti-leakage).
#
# LOGICA ANTI-LEAKAGE (aprobada en la auditoria de Paso 0):
#   1. find_closed_tf_index($tf, $anchor_ts) en MarketData devuelve
#      el indice del bucket cuyo timestamp <= $anchor_ts, restado en 1
#      (el bucket que CONTIENE la barra de aparicion esta "en curso";
#      el ultimo CERRADO es el anterior).
#   2. Si el resultado es undef (la aparicion cae en el primer bucket de
#      esa TF), todos los campos de esa TF se devuelven como undef
#      (no se inventa un valor ni se usa el bucket en curso).
#
# CAMPOS DEL SNAPSHOT:
#   tf_10m => {
#       open, high, low, close, volume,   # de la ultima vela de 10m cerrada
#       ts,                               # timestamp de esa vela
#       index,                            # indice en el array de 10m
#   } | undef
#
#   tf_1h => {
#       open, high, low, close, volume,
#       ts,
#       index,
#   } | undef
#
# =============================================================================

# new() -> $self
# Constructor sin estado: todas las funciones son puras / sin efecto lateral.
sub new {
    my ($class) = @_;
    return bless {}, $class;
}

# snapshot_for_anchor($market_data, $anchor_ts, $anchor_index) -> \%snapshot
#
# Parametros:
#   $market_data   — instancia de Market::MarketData (ya construida con TFs)
#   $anchor_ts     — timestamp (epoch) de la vela de 1m donde ocurrio la aparicion
#   $anchor_index  — indice en 1m de esa vela (para debugging/trazabilidad)
#
# Devuelve un hashref con:
#   {
#     anchor_ts    => $anchor_ts,
#     anchor_index => $anchor_index,
#     tf_10m       => { open,high,low,close,volume,ts,index } | undef,
#     tf_1h        => { open,high,low,close,volume,ts,index } | undef,
#   }
sub snapshot_for_anchor {
    my ($self, $market_data, $anchor_ts, $anchor_index) = @_;

    return {
        anchor_ts    => $anchor_ts,
        anchor_index => $anchor_index,
        tf_10m       => undef,
        tf_1h        => undef,
    } unless $market_data && defined $anchor_ts;

    return {
        anchor_ts    => $anchor_ts,
        anchor_index => $anchor_index,
        tf_10m       => _extract_tf($market_data, '10m', $anchor_ts),
        tf_1h        => _extract_tf($market_data, '1H',  $anchor_ts),
    };
}

# _extract_tf($market_data, $tf, $anchor_ts) -> \%candle_data | undef
#
# Funcion privada: obtiene la vela del ultimo bucket CERRADO de $tf en el
# momento de $anchor_ts. Devuelve undef si no hay bucket previo cerrado
# (caso: aparicion en el primer bucket de esa TF).
sub _extract_tf {
    my ($market_data, $tf, $anchor_ts) = @_;

    # find_closed_tf_index implementa la logica anti-leakage:
    #   - busqueda binaria => bucket con ts <= anchor_ts (el "en curso")
    #   - devuelve ese indice - 1 (el ultimo CERRADO)
    #   - devuelve undef si no hay bucket previo
    my $closed_idx = $market_data->find_closed_tf_index($tf, $anchor_ts);

    # Sin datos cerrados disponibles para esta TF en este momento.
    return undef unless defined $closed_idx;

    # Acceso directo por TF+indice sin mutar active_tf del chart.
    my $candle = $market_data->get_candle_in_tf($tf, $closed_idx);
    return undef unless $candle;

    return {
        open   => $candle->{open},
        high   => $candle->{high},
        low    => $candle->{low},
        close  => $candle->{close},
        volume => $candle->{volume},
        ts     => $candle->{timestamp},
        index  => $closed_idx,
    };
}

1;

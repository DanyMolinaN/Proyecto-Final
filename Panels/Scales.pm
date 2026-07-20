package Market::Panels::Scales;

# =============================================================================
# Market::Panels::Scales  — v2.1
# =============================================================================
# Req-1 — Corrección del Desfase Velas vs. Eje de Tiempo:
#   index_to_x / index_to_center_x mapean ÚNICAMENTE índices de vela.
#   El timestamp de cada vela se obtiene exclusivamente de MarketData, nunca
#   se recalcula ni interpola aquí. Esto elimina el desfase acumulado cuando
#   el eje de tiempo toma un índice relativo al viewport y el renderer toma
#   el índice absoluto del array de datos.
#
#   Invariante garantizada:
#     Scales::index_to_center_x($i) == PricePanel::x_center_for_candle($i)
#   porque ambos usan la misma fórmula:  (i - start_index) * cw + cw/2 + x_shift
#
# Regla de Separación de Responsabilidades (Req-1, Req-5):
#   Esta clase NUNCA recibe ni almacena timestamps. La interpolación temporal
#   vive exclusivamente en ChartEngine::compute_intraday_labels(), que extrae
#   el timestamp desde MarketData::get_timestamp(index) y luego llama a
#   index_to_center_x(index) para posicionar la etiqueta. Separación limpia.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        width           => $args{width}          || 800,
        height          => $args{height}          || 600,
        candle_width    => $args{candle_width}    || 8,
        start_index     => defined $args{start_index} ? $args{start_index} : 0,
        # x_shift: desplazamiento sub-pixel (px) aplicado a TODO el eje X.
        # Permite anclar el zoom con precisión exacta (sub-vela), evitando
        # el desfase acumulado por redondear el offset a velas enteras.
        x_shift         => defined $args{x_shift} ? $args{x_shift} : 0,
        min_value       => defined $args{min_value}   ? $args{min_value}   : 0,
        max_value       => defined $args{max_value}   ? $args{max_value}   : 100,
        padding_top     => $args{padding_top}     || 20,
        padding_bottom  => $args{padding_bottom}  || 20,
        y_offset        => $args{y_offset}        || 0,
        axis_tag        => $args{axis_tag}        || 'y_scale',
        axis_background => $args{axis_background}  || '#181c27',
        y_axis_strip_w  => $args{y_axis_strip_w}   || 66,
        price_precision => $args{price_precision} // 2,
    };
    bless $self, $class;
    return $self;
}

# ── Eje X ─────────────────────────────────────────────────────────────────────
#
# CONTRATO (Req-1 — Sincronización):
#   - $index  es SIEMPRE el índice absoluto en el array de datos (0-based).
#   - start_index es el índice lógico del borde izquierdo del viewport
#     (puede ser negativo si hay whitespace).
#   - Todas las capas (velas, overlays, eje de tiempo, crosshair) usan
#     ESTE método como única fuente de verdad para la coordenada X.

# index_to_x($index) → coordenada X del borde IZQUIERDO de la vela $index.
sub index_to_x {
    my ($self, $index) = @_;
    return (($index - $self->{start_index}) * $self->{candle_width})
         + ($self->{x_shift} || 0);
}

# x_to_index($x) → índice de vela más cercano (entero).
sub x_to_index {
    my ($self, $x) = @_;
    return int((($x - ($self->{x_shift} || 0)) / $self->{candle_width})
               + $self->{start_index});
}

# x_to_index_float($x) → índice continuo (sin redondear; para crosshair).
sub x_to_index_float {
    my ($self, $x) = @_;
    return (($x - ($self->{x_shift} || 0)) / $self->{candle_width})
         + $self->{start_index};
}

# index_to_center_x($index) → coordenada X del CENTRO de la vela $index.
# Usado por TODOS los overlays y por el eje de tiempo para posicionar etiquetas.
# Esta es la función canónica de alineación. Nunca debe duplicarse en overlays.
sub index_to_center_x {
    my ($self, $index) = @_;
    return $self->index_to_x($index) + ($self->{candle_width} / 2);
}

# timestamp_to_x($ts, $market_data) → X del centro de la vela con ese timestamp.
# Req-1: traduce timestamp → índice via MarketData (búsqueda binaria O(log N)),
# luego delega a index_to_center_x. NUNCA interpola el timestamp directamente.
# Sólo usar cuando se dispone de un timestamp arbitrario (no de un índice).
sub timestamp_to_x {
    my ($self, $ts, $market_data) = @_;
    return undef unless defined $ts && $market_data;
    my $idx = _binary_search_timestamp($ts, $market_data);
    return undef unless defined $idx;
    return $self->index_to_center_x($idx);
}

# _binary_search_timestamp($ts, $market_data) → índice O(log N)
# Busca el índice de la vela cuyo timestamp es más cercano a $ts.
# Req-5 (Rendimiento): búsqueda binaria sobre la serie ordenada por tiempo.
sub _binary_search_timestamp {
    my ($ts, $market_data) = @_;
    return undef unless $market_data && $market_data->can('size');
    my $n = $market_data->size();
    return undef unless $n > 0;

    my ($lo, $hi) = (0, $n - 1);
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        my $c   = $market_data->get_candle($mid);
        return $mid unless $c && defined $c->{timestamp};
        my $t = $c->{timestamp};
        if    ($t == $ts) { return $mid; }
        elsif ($t <  $ts) { $lo = $mid + 1; }
        else              { $hi = $mid - 1; }
    }
    # Retornar el índice más cercano
    return $lo < $n ? $lo : ($n - 1);
}

# ── Eje Y ─────────────────────────────────────────────────────────────────────

sub value_to_y {
    my ($self, $value) = @_;
    my $usable = $self->{height} - $self->{padding_top} - $self->{padding_bottom};
    my $range  = $self->{max_value} - $self->{min_value};
    $range = 1 if $range == 0;
    my $y = $self->{height} - $self->{padding_bottom}
          - ((($value - $self->{min_value}) / $range) * $usable);
    return $y + ($self->{y_offset} || 0);
}

sub y_to_value {
    my ($self, $y) = @_;
    my $usable = $self->{height} - $self->{padding_top} - $self->{padding_bottom};
    my $range  = $self->{max_value} - $self->{min_value};
    $range = 1 if $range == 0;
    my $y_local = $y - ($self->{y_offset} || 0);
    return $self->{min_value}
         + ((($self->{height} - $self->{padding_bottom} - $y_local) / $usable) * $range);
}

sub set_range {
    my ($self, $min, $max) = @_;
    return unless defined $min && defined $max;
    if ($min == $max) { $min -= 1; $max += 1; }
    $self->{min_value} = $min;
    $self->{max_value} = $max;
}

sub get_range {
    my ($self) = @_;
    return ($self->{min_value}, $self->{max_value});
}

sub _auto_precision {
    my ($self, $range) = @_;
    return $self->{price_precision} if $self->{price_precision} > 0;
    return 0 if $range >= 1000;
    return 1 if $range >= 100;
    return 2 if $range >= 1;
    return 4 if $range >= 0.01;
    return 6;
}

sub _nice_num {
    my ($self, $x) = @_;
    return 1 unless defined $x && $x > 0;
    my $exp = int(log($x) / log(10));
    $exp = 0 if $exp < 0 && $x >= 1;
    my $f   = $x / (10**$exp);
    my $nf  = $f < 1.5 ? 1 : $f < 3 ? 2 : $f < 7 ? 5 : 10;
    return $nf * (10**$exp);
}

sub _quarter_tick_step {
    my ($self, $range, $max_ticks) = @_;
    $max_ticks = 12 unless defined $max_ticks && $max_ticks > 0;
    return 0.25 unless $range > 0;
    my $step = 0.25;
    while ($range / $step > $max_ticks) {
        $step *= 2;
        last if $step >= 1_000_000;
    }
    return $step;
}

sub _quarter_tick_values {
    my ($self, $min, $max, $max_ticks) = @_;
    my $range = $max - $min;
    return () if $range <= 0;
    my $step  = $self->_quarter_tick_step($range, $max_ticks);
    my $start = $step * int($min / $step);
    $start -= $step while $start > $min;
    my @vals;
    for (my $v = $start; $v <= $max + $step * 0.0001; $v += $step) {
        push @vals, (int($v * 4 + ($v >= 0 ? 0.5 : -0.5))) / 4;
        last if @vals > 50;
    }
    return @vals;
}

sub _draw_y_scale {
    my ($self, $canvas) = @_;
    return unless $canvas;
    my $tag = $self->{axis_tag} || 'y_scale';
    $canvas->delete($tag);
    my $min   = $self->{min_value};
    my $max   = $self->{max_value};
    my $range = $max - $min;
    $range = 1 if $range == 0;
    my $width     = $self->{width};
    my $is_price  = ($self->{axis_tag} || '') eq 'price_y_scale';
    my $precision = $is_price ? 2 : $self->_auto_precision($range);
    my @tick_values;
    if ($is_price) {
        @tick_values = $self->_quarter_tick_values($min, $max, 12);
    } else {
        my $steps = 5;
        my $step  = $range / $steps;
        @tick_values = map { $min + ($step * $_) } 0 .. $steps;
    }
    my $strip_w = $self->{y_axis_strip_w} || 66;
    my $left    = $width - $strip_w;
    $left = 0 if $left < 0;
    my $y_top = $self->{y_offset} || 0;
    my $y_bot = $y_top + $self->{height};
    $canvas->createRectangle(
        $left, $y_top, $width, $y_bot,
        -fill    => $self->{axis_background} || '#181c27',
        -outline => '',
        -tags    => [$tag],
    );
    $canvas->createLine(
        $left, $y_top, $left, $y_bot,
        -fill  => '#2a2e39', -width => 1, -tags => [$tag],
    );
    for my $value (@tick_values) {
        my $y = $self->value_to_y($value);
        next if $y < $y_top - 2 || $y > $y_bot + 2;
        $canvas->createLine(
            0, $y, $width - 22, $y,
            -fill => '#1e2130', -width => 1, -tags => [$tag],
        );
        $canvas->createLine(
            $width - 20, $y, $width - 15, $y,
            -fill => '#555555', -width => 1, -tags => [$tag],
        );
        $canvas->createText(
            $width - 8, $y,
            -text   => $is_price
                     ? sprintf('%.2f', $value)
                     : sprintf("%.*f", $precision, $value),
            -fill   => '#d1d4dc',
            -anchor => 'e',
            -font   => 'Helvetica 10',
            -tags   => [$tag],
        );
    }
}

1;

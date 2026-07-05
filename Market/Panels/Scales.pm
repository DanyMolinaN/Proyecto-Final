package Market::Panels::Scales;

# =============================================================================
# Market::Panels::Scales
# -----------------------------------------------------------------------------
# Sistema de escalas de un panel. Gestiona la transformacion entre coordenadas
# de DATOS (indice de vela, valor de precio/indicador) y coordenadas de
# PANTALLA (x, y en pixeles). El eje X (indices) es comun a todos los paneles;
# el eje Y es propio de cada panel.
#
# Regla clave: NUNCA mezclar coordenadas de datos con coordenadas de pantalla
# fuera de esta clase. Usa siempre los metodos publicos para la conversion.
# =============================================================================

use strict;
use warnings;

# new(%args) -> $self
# Inicializa el sistema de escalas.
#   width, height      : dimensiones del panel en pixeles
#   candle_width       : ancho de cada vela en pixeles
#   start_index        : indice absoluto de la primera vela visible
#   min_value/max_value: rango de datos del eje Y
#   y_offset           : desplazamiento vertical del panel (para paneles apilados)
#   axis_tag           : tag Tk para poder borrar/redibujar la escala Y
#   axis_background    : color del bloque solido del margen derecho (mascara)
#   y_axis_strip_w     : ancho (px) de la franja del eje Y en el borde derecho
#   price_precision    : decimales a mostrar en el eje Y (autodetectado si 0)
sub new {
    my ($class, %args) = @_;
    my $self = {
        width           => $args{width}          || 800,
        height          => $args{height}          || 600,
        candle_width    => $args{candle_width}    || 8,
        start_index     => defined $args{start_index} ? $args{start_index} : 0,
        # Desplazamiento horizontal sub-pixel (en pixeles) aplicado a TODO el eje
        # X. Permite anclar el zoom con precision exacta (sub-vela), evitando el
        # desfase acumulado por redondear el offset a velas enteras.
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

# ── Eje X ────────────────────────────────────────────────────────────────────

# index_to_x($index) -> $x
# Convierte un indice de vela (absoluto) a la coordenada X izquierda en pixeles.
# Incluye el desplazamiento sub-pixel x_shift comun a todo el eje X.
sub index_to_x {
    my ($self, $index) = @_;
    return (($index - $self->{start_index}) * $self->{candle_width})
         + ($self->{x_shift} || 0);
}

# x_to_index($x) -> $index (entero)
# Convierte una coordenada X de pantalla al indice de vela mas cercano.
sub x_to_index {
    my ($self, $x) = @_;
    return int((($x - ($self->{x_shift} || 0)) / $self->{candle_width})
               + $self->{start_index});
}

# x_to_index_float($x) -> $index (continuo)
# Igual que x_to_index pero sin redondear; mas preciso para interaccion.
sub x_to_index_float {
    my ($self, $x) = @_;
    return (($x - ($self->{x_shift} || 0)) / $self->{candle_width})
         + $self->{start_index};
}

# index_to_center_x($index) -> $x
# Devuelve la coordenada X del centro de la vela en ese indice.
sub index_to_center_x {
    my ($self, $index) = @_;
    return $self->index_to_x($index) + ($self->{candle_width} / 2);
}

# ── Eje Y ────────────────────────────────────────────────────────────────────

# value_to_y($value) -> $y
# Convierte un valor (precio o indicador) a su coordenada Y en pixeles,
# considerando el rango [min_value, max_value] y el y_offset del panel.
sub value_to_y {
    my ($self, $value) = @_;
    my $usable = $self->{height} - $self->{padding_top} - $self->{padding_bottom};
    my $range  = $self->{max_value} - $self->{min_value};
    $range = 1 if $range == 0;

    my $y = $self->{height} - $self->{padding_bottom}
          - ((($value - $self->{min_value}) / $range) * $usable);
    return $y + ($self->{y_offset} || 0);
}

# y_to_value($y) -> $value
# Inversa de value_to_y: convierte una coordenada Y de pantalla al valor
# (precio/indicador) correspondiente. Usado para el precio bajo el cursor.
sub y_to_value {
    my ($self, $y) = @_;
    my $usable = $self->{height} - $self->{padding_top} - $self->{padding_bottom};
    my $range  = $self->{max_value} - $self->{min_value};
    $range = 1 if $range == 0;

    my $y_local = $y - ($self->{y_offset} || 0);
    return $self->{min_value}
         + ((($self->{height} - $self->{padding_bottom} - $y_local) / $usable) * $range);
}

# set_range($min, $max)
# Establece el rango del eje Y de forma encapsulada (evita acceso directo al hash).
# Si $min == $max se aplica un margen minimo para evitar division por cero en render.
sub set_range {
    my ($self, $min, $max) = @_;
    return unless defined $min && defined $max;
    if ($min == $max) {
        $min -= 1;
        $max += 1;
    }
    $self->{min_value} = $min;
    $self->{max_value} = $max;
}

# get_range() -> ($min, $max)
# Devuelve el rango actual del eje Y.
sub get_range {
    my ($self) = @_;
    return ($self->{min_value}, $self->{max_value});
}

# _auto_precision($range) -> $decimals
# Calcula automaticamente la precision de decimales para el eje Y segun el
# rango de valores: rangos grandes usan 0-1 decimales; rangos pequenos usan mas.
sub _auto_precision {
    my ($self, $range) = @_;
    return $self->{price_precision} if $self->{price_precision} > 0;
    return 0 if $range >= 1000;
    return 1 if $range >= 100;
    return 2 if $range >= 1;
    return 4 if $range >= 0.01;
    return 6;
}

# _nice_num($x) -> $rounded
# Redondea $x al entero "bonito" mas cercano (1, 2, 5 x 10^n), estilo TradingView.
sub _nice_num {
    my ($self, $x) = @_;
    return 1 unless defined $x && $x > 0;
    my $exp = int(log($x) / log(10));
    $exp = 0 if $exp < 0 && $x >= 1;
    my $f   = $x / (10**$exp);
    my $nf  = $f < 1.5 ? 1 : $f < 3 ? 2 : $f < 7 ? 5 : 10;
    return $nf * (10**$exp);
}

# _quarter_tick_step($range, $max_ticks) -> $step
# Paso base 0.25; si el rango es muy amplio, multiplica por 2 (0.5, 1, 2, 4...).
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

# _quarter_tick_values($min, $max, $max_ticks) -> @values
# Ticks del eje de precios en saltos exactos de 0.25 (o multiplo directo).
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

# _draw_y_scale($canvas)
# Dibuja la escala vertical (marcas y etiquetas de valores) del panel en el
# borde derecho. Usa su axis_tag para borrar/redibujar sin afectar otros elementos.
# La precision de los labels se adapta automaticamente al rango visible.
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

    # Eje de precios: incrementos estrictos 0.25 (x1, x2, x4... si el zoom esta alejado).
    # Eje ATR: conserva division lineal adaptativa (indicador, no OHLC).
    my @tick_values;
    if ($is_price) {
        @tick_values = $self->_quarter_tick_values($min, $max, 12);
    }
    else {
        my $steps = 5;
        my $step  = $range / $steps;
        @tick_values = map { $min + ($step * $_) } 0 .. $steps;
    }

    # Mascara solida del eje Y (estilo TradingView): oculta velas/volumen que
    # "sangran" por detras de los numeros. Se dibuja ANTES de marcas y textos;
    # el crosshair y la caja del ultimo precio se elevan despues en render().
    my $strip_w = $self->{y_axis_strip_w} || 66;
    my $left    = $width - $strip_w;
    $left = 0 if $left < 0;
    my $y_top = $self->{y_offset} || 0;
    my $y_bot = $y_top + $self->{height};
    $canvas->createRectangle(
        $left, $y_top,
        $width, $y_bot,
        -fill    => $self->{axis_background} || '#181c27',
        -outline => '',
        -tags    => [$tag],
    );

    # Separador vertical entre el area del grafico y el panel de precios del eje Y.
    $canvas->createLine(
        $left, $y_top,
        $left, $y_bot,
        -fill  => '#2a2e39',
        -width => 1,
        -tags  => [$tag],
    );

    for my $value (@tick_values) {
        my $y = $self->value_to_y($value);
        next if $y < $y_top - 2 || $y > $y_bot + 2;

        # Linea de cuadricula horizontal sutil a traves de todo el panel
        $canvas->createLine(
            0,          $y,
            $width - 22, $y,
            -fill  => '#1e2130',
            -width => 1,
            -tags  => [$tag],
        );

        # Linea de marca en el borde derecho
        $canvas->createLine(
            $width - 20, $y,
            $width - 15, $y,
            -fill  => '#555555',
            -width => 1,
            -tags  => [$tag],
        );

        # Etiqueta de valor con precision adaptativa (legible sobre fondo oscuro).
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

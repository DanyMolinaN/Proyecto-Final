package Market::Panels::PricePanel;

# =============================================================================
# Market::Panels::PricePanel
# -----------------------------------------------------------------------------
# Capa de RENDER del panel principal de precios. Dibuja las velas OHLC,
# el escalado vertical, el crosshair y la etiqueta de precio bajo el cursor.
# Recibe la escala (Scales) para convertir datos -> pixeles; no calcula datos.
#
# Mejoras respecto a la version original:
#   - Linea horizontal punteada del ultimo precio (como TradingView)
#   - Caja del ultimo precio posicionada dinamicamente con $scale->{width}
#   - Separador visual (linea) entre el panel de precios y el panel ATR
#   - Precision de precio adaptativa
# =============================================================================

use strict;
use warnings;

# new(%args) -> $self
# Inicializa el panel de precios (colores alcista/bajista, fondo, precision).
sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
        scale           => undef,
        bullish_color   => '#26a69a',
        bearish_color   => '#ef5350',
        background      => '#131722',
        price_precision => $args{price_precision} // 2,
        crosshair       => {},
        # Ancho (px) reservado para la etiqueta del eje Y bajo el cursor. Sirve a
        # la vez como margen donde termina la linea horizontal del crosshair.
        _y_axis_label_w => 66,
    };
    bless $self, $class;
    return $self;
}

# _init_crosshair_objects($canvas)
# Crea una sola vez los objetos graficos reutilizables del crosshair (lineas
# y etiqueta de precio). En llamadas posteriores no hace nada.
sub _init_crosshair_objects {
    my ($self, $canvas) = @_;
    return unless $canvas;
    return if $self->{crosshair}->{initialized};

    # Lineas punteadas estilo TradingView: gris tenue (#9598a1) en lugar de blanco
    # puro, para que destaquen sobre el fondo sin resultar agresivas.
    my $vid = $canvas->createLine(0, 0, 0, 0,
        -fill => '#9598a1', -width => 1, -dash => [4, 3],
        -tags => ['price_crosshair']);
    my $hid = $canvas->createLine(0, 0, 0, 0,
        -fill => '#9598a1', -width => 1, -dash => [4, 3],
        -tags => ['price_crosshair']);

    # Etiqueta que muestra el precio exacto a la altura del cursor.
    # Se reutilizan estos objetos (no se recrean) para no afectar el rendimiento.
    # Fondo negro solido SIN borde (look TradingView, sin gris que "ensucie").
    my $box_id = $canvas->createRectangle(0, 0, 0, 0,
        -fill => '#000000', -outline => '',
        -tags => ['price_crosshair_label']);
    my $txt_id = $canvas->createText(0, 0,
        -text => '', -fill => '#ffffff', -anchor => 'e',
        -font => 'Helvetica 8 bold',
        -tags => ['price_crosshair_label']);

    # Etiqueta que muestra la fecha/hora de la vela bajo el cursor, sobre el
    # eje de tiempo (parte inferior del panel). Tambien se reutiliza.
    my $time_box_id = $canvas->createRectangle(0, 0, 0, 0,
        -fill => '#000000', -outline => '',
        -tags => ['price_crosshair_label']);
    my $time_txt_id = $canvas->createText(0, 0,
        -text => '', -fill => '#ffffff', -anchor => 'c',
        -font => 'Helvetica 8 bold',
        -tags => ['price_crosshair_label']);

    $self->{crosshair} = {
        vertical_id   => $vid,
        horizontal_id => $hid,
        label_box_id  => $box_id,
        label_text_id => $txt_id,
        time_box_id   => $time_box_id,
        time_text_id  => $time_txt_id,
        initialized   => 1,
    };
}

# round($value) -> $int
# Redondeo auxiliar al entero mas cercano (para calculos de pixeles).
sub round {
    my ($self, $value) = @_;
    return int($value + 0.5);
}

# render($canvas, $data, $scale)
# Funcion principal del panel: dibuja las velas visibles ($data = slice OHLC)
# usando $scale para mapear indice/precio a pixeles. Borra y redibuja la capa
# de velas en cada llamada.
sub render {
    my ($self, $canvas, $data, $scale, $first_index) = @_;
    return unless $canvas && $scale && $data && ref $data eq 'ARRAY' && @$data;

    $canvas->configure(-background => $self->{background});
    $canvas->delete('candles', 'visible_price', 'visible_background',
                    'time_labels', 'price_y_scale', 'last_price_line',
                    'panel_separator', 'volume_bars');
    $self->_init_crosshair_objects($canvas);

    my $candle_width = $scale->{candle_width};
    # Indice absoluto de la PRIMERA vela del slice. Por defecto = start_index de
    # la escala; pero cuando el motor envia velas de relleno en los bordes, pasa
    # un $first_index explicito (menor que start_index) para posicionarlas bien.
    my $start_index  = defined $first_index ? $first_index : ($scale->{start_index} || 0);

    my $stride = $scale->{draw_stride} || 1;

    # Zoom-out / muestreo: una sola polilinea (cierre) en todas las temporalidades.
    if ($stride > 1) {
        $self->_render_close_line($canvas, $data, $scale, $start_index, $stride);
        $self->render_last_visible_price($canvas, $data, $scale);
        $self->_draw_panel_separator($canvas, $scale);
        return;
    }

    # Calcular volumen maximo visible para normalizar las barras de volumen
    my $max_volume = 0;
    foreach my $candle (@$data) {
        next unless $candle && defined $candle->{volume};
        $max_volume = $candle->{volume} if $candle->{volume} > $max_volume;
    }
    my $vol_area_height = ($scale->{height} - $scale->{padding_top} - $scale->{padding_bottom}) * 0.15;
    my $vol_base_y      = $scale->{height} - $scale->{padding_bottom} + ($scale->{y_offset} || 0);

    for (my $rel_index = 0; $rel_index <= $#$data; $rel_index++) {
        my $candle = $data->[$rel_index];
        next unless $candle;

        my $abs_index = $start_index + ($rel_index * $stride);
        my $x         = $scale->index_to_x($abs_index);
        my $center_x  = $scale->index_to_center_x($abs_index);

        my $open_y  = $scale->value_to_y($candle->{open});
        my $high_y  = $scale->value_to_y($candle->{high});
        my $low_y   = $scale->value_to_y($candle->{low});
        my $close_y = $scale->value_to_y($candle->{close});

        my $color = $candle->{close} >= $candle->{open}
            ? $self->{bullish_color}
            : $self->{bearish_color};

        # Barras de volumen semitransparentes en la base del panel de precios.
        # Se omiten cuando las velas son muy finas (candle_width < 2 px): a ese
        # nivel de zoom-out son imperceptibles y duplican los objetos a dibujar,
        # lo que degrada la fluidez con muchas velas en pantalla.
        if ($candle_width >= 2
            && $max_volume > 0 && defined $candle->{volume} && $candle->{volume} > 0) {
            my $vol_h = ($candle->{volume} / $max_volume) * $vol_area_height;
            my $vx1   = $x + 1;
            my $vx2   = $x + $candle_width - 1;
            $vx2 = $vx1 + 1 if $vx2 <= $vx1;
            my $vol_color = $candle->{close} >= $candle->{open} ? '#1a4a46' : '#4a1a1a';
            $canvas->createRectangle(
                $vx1, $vol_base_y - $vol_h,
                $vx2, $vol_base_y,
                -fill    => $vol_color,
                -outline => '',
                -tags    => ['volume_bars'],
            );
        }

        # Mecha high-low
        $canvas->createLine(
            $center_x, $high_y,
            $center_x, $low_y,
            -fill => $color,
            -tags => ['candles'],
        );

        # Cuerpo de la vela. Se dibuja SIEMPRE (incluso con zoom-out alto)
        # garantizando un ancho minimo de 1px, para que el cuerpo nunca
        # desaparezca y el efecto del zoom siga siendo perceptible. Con velas
        # anchas (>2px) se deja 1px de separacion a cada lado; con velas muy
        # angostas se ocupa todo el ancho disponible.
        my $body_top    = $open_y < $close_y ? $open_y  : $close_y;
        my $body_bottom = $open_y > $close_y ? $open_y  : $close_y;

        my $inset   = $candle_width > 2 ? 1 : 0;
        my $body_x1 = $x + $inset;
        my $body_x2 = $x + $candle_width - $inset;
        $body_x2 = $body_x1 + 1 if $body_x2 <= $body_x1;   # ancho minimo 1px

        $canvas->createRectangle(
            $body_x1, $body_top,
            $body_x2, $body_bottom,
            -fill    => $color,
            -outline => $color,
            -tags    => ['candles'],
        );
    }

    $self->render_last_visible_price($canvas, $data, $scale);
    $self->_draw_panel_separator($canvas, $scale);
}

# _render_close_line($canvas, $data, $scale, $start_index, $stride)
# Modo rapido para zoom-out alto: trazo unico del cierre (sin alterar datos OHLC).
sub _render_close_line {
    my ($self, $canvas, $data, $scale, $start_index, $stride) = @_;
    return unless $canvas && $data && $scale && @$data;

    $stride = 1 unless $stride && $stride > 0;
    my @coords;
    for (my $rel_index = 0; $rel_index <= $#$data; $rel_index++) {
        my $candle = $data->[$rel_index];
        next unless $candle && defined $candle->{close};
        my $abs_index = $start_index + ($rel_index * $stride);
        push @coords,
            $scale->index_to_center_x($abs_index),
            $scale->value_to_y($candle->{close});
    }
    my $last = $data->[-1];
    if ($last && defined $last->{close}) {
        my $last_idx = defined $scale->{draw_end_index}
                     ? $scale->{draw_end_index}
                     : ($start_index + ($#$data * $stride));
        my $lx = $scale->index_to_center_x($last_idx);
        my $ly = $scale->value_to_y($last->{close});
        if (!@coords || $coords[-2] != $lx || $coords[-1] != $ly) {
            push @coords, $lx, $ly;
        }
    }
    return unless @coords >= 4;

    $canvas->createLine(
        @coords,
        -fill   => '#787b86',
        -width  => 1,
        -smooth => 0,
        -tags   => ['candles'],
    );
}

# render_last_visible_price($canvas, $data, $scale)
# Dibuja:
#   1. Una linea horizontal punteada al nivel del ultimo precio (como TradingView).
#   2. La caja destacada con el valor numerico en el borde derecho.
# Posicionamiento dinamico: usa $scale->{width} para adaptarse a cualquier
# ancho de ventana.
sub render_last_visible_price {
    my ($self, $canvas, $data, $scale) = @_;
    return unless $canvas && $data && ref $data eq 'ARRAY' && @$data && $scale;

    my $last = $data->[-1];
    return unless $last;

    my $price = $last->{close};
    my $text  = sprintf("%.*f", $self->{price_precision}, $price);
    my $y     = $scale->value_to_y($price);
    my $width = $scale->{width};

    # Determina el color segun si la vela es alcista o bajista
    my $color = ($last->{close} >= $last->{open})
        ? $self->{bullish_color}
        : $self->{bearish_color};

    # --- Linea horizontal punteada del precio actual ---
    # Se extiende desde x=0 hasta el borde derecho (dejando espacio para la caja)
    $canvas->delete('last_price_line', 'visible_price', 'visible_background');
    $canvas->createLine(
        0,          $y,
        $width - 62, $y,
        -fill  => $color,
        -width => 1,
        -dash  => [4, 3],
        -tags  => ['last_price_line'],
    );

    # --- Caja con el precio numerico (borde derecho) ---
    my $box_right  = $width - 2;
    my $box_left   = $width - 60;
    my $box_top    = $y - 10;
    my $box_bottom = $y + 10;

    $canvas->createRectangle(
        $box_left, $box_top,
        $box_right, $box_bottom,
        -fill    => $color,
        -outline => $color,
        -tags    => ['visible_background'],
    );
    $canvas->createText(
        $box_right - 4, $y,
        -text   => $text,
        -fill   => '#ffffff',
        -anchor => 'e',
        -font   => 'Helvetica 9 bold',
        -tags   => ['visible_price'],
    );
}

# get_y_range($data) -> ($min, $max)
# Calcula el precio minimo (low) y maximo (high) de las velas visibles.
# Base para el escalado vertical automatico.
sub get_y_range {
    my ($self, $data) = @_;
    return unless $data && ref $data eq 'ARRAY' && @$data;

    my ($min, $max);
    foreach my $candle (@$data) {
        next unless $candle;
        $min = !defined $min || $candle->{low}  < $min ? $candle->{low}  : $min;
        $max = !defined $max || $candle->{high} > $max ? $candle->{high} : $max;
    }
    return ($min, $max);
}

# set_scale($scale)
# Asigna la escala (Scales) usada para mapear valores a pixeles.
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# draw_time_axis($canvas, $labels, $scale, $baseline_y)
# Dibuja el eje horizontal de tiempo: marcas y etiquetas (HH:MM / fecha) en
# las posiciones dadas por $labels (cada uno con index absoluto y text).
# Si se pasa $baseline_y, el eje se dibuja a esa altura (fondo del grafico,
# debajo del panel ATR); si no, cae al borde inferior del panel de precios.
sub draw_time_axis {
    my ($self, $canvas, $labels, $scale, $baseline_y, $strip_height) = @_;
    return unless $canvas && $scale && $labels && ref $labels eq 'ARRAY';

    $canvas->delete('time_labels');
    my $y_tick = defined $baseline_y
        ? $baseline_y
        : $scale->{height} - $scale->{padding_bottom};
    my $y_base = $y_tick + 14;
    my $width  = $scale->{width} || 0;
    my $strip_h = $strip_height || 42;

    # Fondo de la franja del eje X (ligeramente distinto al panel principal).
    if ($width > 0) {
        my $y_bot = $y_tick + $strip_h;
        $canvas->createRectangle(
            0, $y_tick,
            $width, $y_bot,
            -fill    => '#181c27',
            -outline => '',
            -tags    => ['time_labels'],
        );
        # Separador horizontal entre el grafico y el panel de tiempo.
        $canvas->createLine(
            0, $y_tick,
            $width, $y_tick,
            -fill  => '#2a2e39',
            -width => 1,
            -tags  => ['time_labels'],
        );
    }

    foreach my $label (@$labels) {
        next unless defined $label->{index} && defined $label->{text};
        my $x = $scale->index_to_center_x($label->{index});

        # Marca vertical en la base del panel
        $canvas->createLine(
            $x, $y_tick - 5,
            $x, $y_tick,
            -fill  => '#4a4e59',
            -width => 1,
            -tags  => ['time_labels'],
        );

        # Etiqueta de texto (mas legible sobre fondo oscuro).
        $canvas->createText(
            $x, $y_base,
            -text   => $label->{text},
            -fill   => '#d1d4dc',
            -anchor => 'n',
            -font   => 'Helvetica 10',
            -tags   => ['time_labels'],
        );
    }
}

# draw_crosshair($canvas, $x, $y, $top, $bottom)
# Posiciona el crosshair (linea vertical en $x; horizontal en $y si esta
# dentro del panel) y actualiza/oculta la etiqueta de precio.
sub draw_crosshair {
    my ($self, $canvas, $x, $y, $top, $bottom) = @_;
    return unless $canvas && defined $x && defined $y;

    $self->_init_crosshair_objects($canvas);
    my $v = $self->{crosshair}->{vertical_id};
    my $h = $self->{crosshair}->{horizontal_id};
    return unless $v && $h;

    $canvas->coords($v, $x, $top, $x, $bottom);

    if ($y >= $top && $y <= $bottom) {
        # La linea horizontal termina justo en el borde IZQUIERDO de la etiqueta
        # del eje Y (no pasa por detras de la caja), para un acabado limpio.
        my $h_end = $self->{scale}->{width} - $self->{_y_axis_label_w};
        $canvas->coords($h, 0, $y, $h_end, $y);
        $self->_update_price_label($canvas, $y);
    }
    else {
        $canvas->coords($h, 0, 0, 0, 0);
        $self->_hide_price_label($canvas);
    }

    # Elevar las lineas del crosshair por ENCIMA de velas/volumen (que se
    # recrean en cada render y quedarian tapandolas). Las etiquetas se elevan
    # despues en _update_price_label / draw_time_label, quedando sobre las lineas.
    $canvas->raise('price_crosshair');
    $canvas->raise('price_crosshair_label');
}

# _round_quarter_tick_display($price) -> $rounded
# CAMBIODECIMALES: redondeo al cuarto de tick mas cercano (.00 .25 .50 .75)
# solo para el texto mostrado en la cajita negra del crosshair (no altera datos).
sub _round_quarter_tick_display {
    my ($self, $price) = @_;
    return 0 unless defined $price;
    # Enteros de cuartos (4 por unidad) evitan errores de coma flotante en centavos.
    my $quarters = int($price * 4 + ($price >= 0 ? 0.5 : -0.5));
    return $quarters / 4;
}

# _format_crosshair_price_label($price) -> $text
# Formato fijo a 2 decimales en pasos de 0.25 (CAMBIODECIMALES).
sub _format_crosshair_price_label {
    my ($self, $price) = @_;
    my $rounded = $self->_round_quarter_tick_display($price);
    return sprintf('%.2f', $rounded);
}

# _update_price_label($canvas, $y)
# Coloca la etiqueta de precio en el borde derecho, a la altura del cursor,
# convirtiendo la coordenada Y de pantalla al precio correspondiente.
sub _update_price_label {
    my ($self, $canvas, $y) = @_;
    my $scale = $self->{scale};
    return unless $scale;
    my $c = $self->{crosshair};
    return unless $c && $c->{label_box_id};

    my $price = $scale->y_to_value($y);
    my $text  = $self->_format_crosshair_price_label($price);
    my $width = $scale->{width};
    # Caja mas alta (±11) y texto separado del borde (7 px) para que respire.
    my $left  = $width - $self->{_y_axis_label_w};

    $canvas->coords($c->{label_box_id}, $left, $y - 11, $width, $y + 11);
    $canvas->coords($c->{label_text_id}, $width - 7, $y);
    $canvas->itemconfigure($c->{label_text_id}, -text => $text);
    $canvas->itemconfigure($c->{label_box_id},  -state => 'normal');
    $canvas->itemconfigure($c->{label_text_id}, -state => 'normal');
    $canvas->raise('price_crosshair_label');
}

sub _hide_price_label {
    my ($self, $canvas) = @_;
    my $c = $self->{crosshair};
    return unless $c && $c->{label_box_id};
    $canvas->itemconfigure($c->{label_box_id},  -state => 'hidden');
    $canvas->itemconfigure($c->{label_text_id}, -state => 'hidden');
}

# hide_crosshair($canvas)
# Oculta lineas y etiquetas del crosshair (p. ej. cursor sobre el eje Y de precios).
sub hide_crosshair {
    my ($self, $canvas) = @_;
    return unless $canvas;
    $self->_init_crosshair_objects($canvas);
    my $c = $self->{crosshair};
    return unless $c && $c->{vertical_id};
    $canvas->coords($c->{vertical_id},   0, 0, 0, 0);
    $canvas->coords($c->{horizontal_id}, 0, 0, 0, 0);
    $self->_hide_price_label($canvas);
    $self->_hide_time_label($canvas);
}

# draw_time_label($canvas, $x, $text, $baseline_y)
# Dibuja (o actualiza) la etiqueta de fecha/hora sobre el eje de tiempo,
# centrada horizontalmente en $x. Si se pasa $baseline_y, la etiqueta se coloca
# en esa franja (fondo del grafico); si no, cae al borde inferior del panel de
# precios. Si $text esta vacio/indefinido, oculta la etiqueta. El texto lo
# provee ChartEngine (capa que conoce los datos); aqui solo se posiciona.
sub draw_time_label {
    my ($self, $canvas, $x, $text, $baseline_y) = @_;
    return unless $canvas && defined $x;

    $self->_init_crosshair_objects($canvas);
    my $c = $self->{crosshair};
    return unless $c && $c->{time_box_id};

    unless (defined $text && length $text) {
        $self->_hide_time_label($canvas);
        return;
    }

    my $scale = $self->{scale};
    my $width = $scale ? $scale->{width} : 0;

    # Posicion vertical: centrada sobre la fila de la etiqueta estatica del eje
    # (baseline + ~16) para que el bloque la cubra limpiamente, no que flote.
    my $y_axis = defined $baseline_y
        ? $baseline_y + 16
        : ($scale ? $scale->{height} - $scale->{padding_bottom} + 16 : 16);

    # Ancho de la caja con padding mas holgado (texto que respira a los lados).
    my $half_w = (length($text) * 4.0) + 10;
    my $left   = $x - $half_w;
    my $right  = $x + $half_w;

    # Acotar a los bordes del panel para que la etiqueta no quede fuera de vista.
    if ($left < 0) {
        $left  = 0;
        $right = 2 * $half_w;
    }
    if ($width && $right > $width) {
        $right = $width;
        $left  = $width - 2 * $half_w;
    }
    my $cx = ($left + $right) / 2;

    # Caja mas alta (±11) que cubre por completo la etiqueta estatica inferior.
    $canvas->coords($c->{time_box_id}, $left, $y_axis - 11, $right, $y_axis + 11);
    $canvas->coords($c->{time_text_id}, $cx, $y_axis);
    $canvas->itemconfigure($c->{time_text_id}, -text => $text);
    $canvas->itemconfigure($c->{time_box_id},  -state => 'normal');
    $canvas->itemconfigure($c->{time_text_id}, -state => 'normal');
    $canvas->raise('price_crosshair_label');
}

sub _hide_time_label {
    my ($self, $canvas) = @_;
    my $c = $self->{crosshair};
    return unless $c && $c->{time_box_id};
    $canvas->itemconfigure($c->{time_box_id},  -state => 'hidden');
    $canvas->itemconfigure($c->{time_text_id}, -state => 'hidden');
}

# _draw_panel_separator($canvas, $scale)
# Dibuja una linea horizontal fina que separa visualmente el panel de precios
# del panel ATR inferior (equivalente al separador de TradingView).
sub _draw_panel_separator {
    my ($self, $canvas, $scale) = @_;
    return unless $canvas && $scale;

    my $y = $scale->{height} + ($scale->{y_offset} || 0);
    $canvas->delete('panel_separator');
    $canvas->createLine(
        0,               $y,
        $scale->{width}, $y,
        -fill  => '#2a2e39',
        -width => 2,
        -tags  => ['panel_separator'],
    );
}

1;

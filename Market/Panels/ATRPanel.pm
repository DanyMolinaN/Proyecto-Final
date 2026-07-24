package Market::Panels::ATRPanel;

# =============================================================================
# Market::Panels::ATRPanel
# -----------------------------------------------------------------------------
# Capa de RENDER del panel del indicador ATR, en su propio sub-panel con
# escala vertical independiente. Dibuja la linea del ATR, su valor actual y el
# crosshair sincronizado. Recibe la serie de valores y la escala; no calcula.
#
# Mejoras respecto a la version original:
#   - render_last_visible_value usa $scale->{width} (posicion dinamica)
#   - Correccion de firma: render_last_visible_value ahora usa $values y $scale
#   - Label del ATR posicionado correctamente con el y_offset del panel
#   - Precision de decimales adaptativa segun el rango del ATR visible
# =============================================================================

use strict;
use warnings;

# new(%args) -> $self
# Inicializa el panel ATR (color de linea, fondo).
sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
        scale      => undef,
        line_color => '#4dd0e1',
        background => '#0f1720',
        crosshair  => {},
    };
    bless $self, $class;
    $self->_init_crosshair();
    return $self;
}

# _init_crosshair()
# Configura el estado del crosshair del panel (estructura reutilizable).
sub _init_crosshair {
    my ($self) = @_;
    $self->{crosshair} ||= {};
}

# set_scale($scale)
# Asigna la escala vertical independiente del panel ATR.
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# get_y_range(\@values) -> ($min, $max)
# Calcula el rango vertical del ATR visible, con un pequeno margen (padding).
sub get_y_range {
    my ($self, $values) = @_;
    return unless $values && ref $values eq 'ARRAY' && @$values;

    my ($min, $max);
    foreach my $v (@$values) {
        next unless defined $v;
        $min = !defined $min || $v < $min ? $v : $min;
        $max = !defined $max || $v > $max ? $v : $max;
    }
    return unless defined $min && defined $max;

    if ($min == $max) {
        $min -= 1;
        $max += 1;
    }

    my $padding = ($max - $min) * 0.08;
    $padding = 0.1 if $padding == 0;
    return ($min - $padding, $max + $padding);
}

# render($canvas, \@values, $scale)
# Dibuja la linea del ATR uniendo los valores visibles, mapeados a pixeles
# con $scale. Borra y redibuja la capa del ATR en cada llamada.
sub render {
    my ($self, $canvas, $values, $scale, $first_index) = @_;
    return unless $canvas && $scale && $values && ref $values eq 'ARRAY' && @$values;

    $canvas->delete('atr_line', 'atr_last_value', 'atr_y_scale',
                    'atr_crosshair', 'atr_background');

    my @coords;
    # Indice absoluto del primer valor (ver PricePanel::render). Permite alinear
    # el ATR con las velas cuando hay relleno de bordes.
    my $start_index = defined $first_index ? $first_index : ($scale->{start_index} || 0);

    my $n      = scalar @$values;
    my $stride = $scale->{draw_stride} || 1;

    for (my $rel_index = 0; $rel_index < $n; $rel_index++) {
        my $v = $values->[$rel_index];
        next unless defined $v;
        my $abs_index = $start_index + ($rel_index * $stride);
        push @coords,
            $scale->index_to_center_x($abs_index),
            $scale->value_to_y($v);
    }
    if ($n > 0 && defined $values->[-1]) {
        my $last_idx = defined $scale->{draw_end_index}
                     ? $scale->{draw_end_index}
                     : ($start_index + (($n - 1) * $stride));
        my $lx = $scale->index_to_center_x($last_idx);
        my $ly = $scale->value_to_y($values->[-1]);
        if (!@coords || $coords[-2] != $lx || $coords[-1] != $ly) {
            push @coords, $lx, $ly;
        }
    }

    if (@coords >= 4) {
        my $y_top = ($scale->{y_offset} || 0) + ($scale->{padding_top} || 20);
        my $y_bot = ($scale->{y_offset} || 0) + $scale->{height}
                  - ($scale->{padding_bottom} || 20);
        for (my $i = 1; $i < @coords; $i += 2) {
            my $y = $coords[$i];
            $coords[$i] = $y_top if $y < $y_top;
            $coords[$i] = $y_bot if $y > $y_bot;
        }

        $canvas->createLine(
            @coords,
            -fill   => $self->{line_color},
            -width  => 2,
            -smooth => 0,
            -tags   => ['atr_line'],
        );
    }

    $self->render_last_visible_value($canvas, $values, $scale);
}

# render_last_visible_value($canvas, \@values, $scale)
# Muestra la caja con el ultimo valor del ATR en el borde derecho del panel.
# Posicionamiento dinamico: usa $scale->{width} y $scale->{y_offset} para
# adaptarse a cualquier tamano de ventana y altura de panel.
sub render_last_visible_value {
    my ($self, $canvas, $values, $scale) = @_;
    return unless $canvas && $values && ref $values eq 'ARRAY' && @$values && $scale;

    # Busca el ultimo valor definido
    my $last;
    for my $i (reverse 0 .. $#$values) {
        if (defined $values->[$i]) {
            $last = $values->[$i];
            last;
        }
    }
    return unless defined $last;

    # Precision adaptativa: si el ATR es grande (>10), 2 decimales bastan;
    # si es pequeno (precios de forex), se necesitan mas.
    my $precision = $last >= 10 ? 2 : $last >= 1 ? 3 : 4;
    my $text  = sprintf("ATR: %.*f", $precision, $last);

    # Badge dentro del area del panel (izquierda), NO sobre la franja del eje Y
    # derecho — ahi va el zoom vertical estilo TradingView.
    my $y_top      = ($scale->{y_offset} || 0) + 5;
    my $box_left   = 4;
    my $box_right  = 86;
    my $box_top    = $y_top;
    my $box_bottom = $y_top + 18;

    $canvas->delete('atr_last_value', 'atr_background');

    $canvas->createRectangle(
        $box_left, $box_top,
        $box_right, $box_bottom,
        -fill    => '#0a0e19',
        -outline => '#ff9800',
        -width   => 1,
        -tags    => ['atr_background'],
    );
    $canvas->createText(
        $box_right - 4,
        $y_top + 9,
        -text   => $text,
        -fill   => '#ff9800',
        -anchor => 'e',
        -font   => 'Helvetica 8 bold',
        -tags   => ['atr_last_value'],
    );
}

# draw_crosshair($canvas, $x, $y, $top, $bottom)
# Dibuja el crosshair del panel ATR, sincronizado en X con los demas paneles.
sub draw_crosshair {
    my ($self, $canvas, $x, $y, $top, $bottom) = @_;
    return unless $canvas && defined $x && defined $y;

    $canvas->delete('atr_crosshair');

    # Linea vertical (siempre visible mientras el mouse este en cualquier panel)
    # Gris tenue punteado, consistente con el panel de precios (look TradingView).
    $canvas->createLine(
        $x, $top,
        $x, $bottom,
        -fill  => '#9598a1',
        -width => 1,
        -dash  => [4, 3],
        -tags  => ['atr_crosshair'],
    );

    # Linea horizontal + etiqueta de valor: solo si el cursor esta dentro del
    # panel ATR. Replica el comportamiento del panel principal (caja de valor en
    # el borde derecho, a la altura del cursor). Solo convierte Y->valor con la
    # escala; no altera el calculo del ATR.
    if (defined $self->{scale} && $y >= $top && $y <= $bottom) {
        my $width    = $self->{scale}->{width};
        my $label_w  = 66;   # mismo margen que el panel de precios
        # La horizontal termina en el borde izquierdo de la etiqueta del eje Y.
        $canvas->createLine(
            0,             $y,
            $width - $label_w, $y,
            -fill  => '#9598a1',
            -width => 1,
            -dash  => [4, 3],
            -tags  => ['atr_crosshair'],
        );

        my $value = $self->{scale}->y_to_value($y);
        my $text  = sprintf('%.4f', $value);
        my $left      = $width - $label_w;

        # Caja negra solida sin borde y con mas padding vertical (±11).
        $canvas->createRectangle(
            $left, $y - 11,
            $width, $y + 11,
            -fill    => '#000000',
            -outline => '',
            -tags    => ['atr_crosshair'],
        );
        $canvas->createText(
            $width - 7, $y,
            -text   => $text,
            -fill   => '#ffffff',
            -anchor => 'e',
            -font   => 'Helvetica 8 bold',
            -tags   => ['atr_crosshair'],
        );
    }
}

1;

package Market::Overlays::ZigZagVP2DavidOverlay;

# =============================================================================
# Market::Overlays::ZigZagVP2DavidOverlay
#
# Portado desde Proyecto_David/Market/Overlays/ZigZagVolumeProfile2.pm
# Adaptaciones para Kevin:
#   - Package renombrado a ZigZagVP2DavidOverlay.
#   - TAG cambiado a 'david_zzvp2' (evita colision con tags legacy de Kevin).
#   - sub render() reemplazada por sub draw(%args) — contrato del render loop
#     de Kevin (_draw_overlays llama $overlay->draw(canvas=>..., scale=>...)).
#   - La logica interna de dibujo es identica al original de David.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'david_zzvp2';

use constant {
    C_LINE     => '#4f8cff',
    C_CHANNEL  => '#888888',
    C_BIN_LOW  => '#00e676',
    C_BIN_HIGH => '#2979ff',
    C_POC      => '#ff1744',
    LINE_WIDTH      => 2,
    POC_LINE_WIDTH  => 2,
    BIN_LINE_WIDTH  => 5,
    POC_EXTEND_BARS => 15,
    MAX_PROFILES_DRAWN => 3,
};

sub tag { return TAG; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source              => $args{source},
        show_zigzag         => $args{show_zigzag}         // 1,
        show_channel        => $args{show_channel}        // 0,
        show_volume_profile => $args{show_volume_profile} // 0,
        show_poc            => $args{show_poc}            // 0,
        # enabled: gestionado por OverlayManager (enable/disable)
        enabled             => 0,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# draw(%args): contrato del render loop de Kevin.
# Recibe canvas y scale desde _draw_overlays via named args.
sub draw {
    my ( $self, %args ) = @_;
    my $canvas = $args{canvas};
    my $scale  = $args{scale};
    return unless $canvas && $scale;

    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    $self->_render_profiles( $canvas, $scale, $src )
        if $self->{show_channel} || $self->{show_volume_profile} || $self->{show_poc};
    $self->_render_zigzag( $canvas, $scale, $src ) if $self->{show_zigzag};
}

# clear($canvas): llamado por _draw_overlays cuando el overlay esta desactivado.
sub clear {
    my ( $self, $canvas ) = @_;
    $canvas->delete(TAG) if $canvas;
}

# _price_in_range: verifica si un precio está dentro del rango visible.
# Scales.pm de Kevin expone {min_value} y {max_value} directamente.
sub _price_in_range {
    my ( $scale, $price ) = @_;
    return defined($price)
        && $price >= $scale->{min_value}
        && $price <= $scale->{max_value};
}

# _visible_bars: barras visibles en el viewport.
# Scales.pm de Kevin usa {width} y {candle_width}; no existe {visible_bars}.
sub _visible_bars {
    my ($scale) = @_;
    my $cw = $scale->{candle_width} || 8;
    return int( ( $scale->{width} || 800 ) / $cw ) + 1;
}

sub _render_zigzag {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_segments');

    # Scales.pm de Kevin: start_index es el borde izquierdo del viewport.
    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);
    # En replay, draw_end_index = puntero: no dibujar piernas del futuro.
    my $max_idx = $scale->{draw_end_index};
    $max_idx = $off + $vb if !defined $max_idx;

    my $segments = $src->get_segments;
    return unless $segments && @$segments;

    for my $s (@$segments) {
        next if !defined $s->{from_index} || !defined $s->{to_index};
        next if $s->{from_index} > $max_idx;  # pierna enteramente futura
        next if $s->{to_index} < $off || $s->{from_index} > $off + $vb;

        my $to_i = $s->{to_index};
        $to_i = $max_idx if $to_i > $max_idx;

        my $x1 = $scale->index_to_center_x( $s->{from_index} );
        my $y1 = $scale->value_to_y( $s->{from_price} );
        my $x2 = $scale->index_to_center_x( $to_i );
        my $y2 = $scale->value_to_y( $s->{to_price} );

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill  => C_LINE,
            -width => LINE_WIDTH,
            -tags  => [TAG] );
    }
}

sub _render_profiles {
    my ( $self, $canvas, $scale, $src ) = @_;
    return unless $src->can('get_profiles');
    my $profiles = $src->get_profiles;
    return unless $profiles && @$profiles;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);
    my $max_idx = $scale->{draw_end_index};
    $max_idx = $off + $vb if !defined $max_idx;

    my $start = $#$profiles - MAX_PROFILES_DRAWN + 1;
    $start = 0 if $start < 0;

    for my $k ( $start .. $#$profiles ) {
        my $prof = $profiles->[$k];
        my ( $lo_idx, $hi_idx ) = $prof->{idx_from} < $prof->{idx_to}
            ? ( $prof->{idx_from}, $prof->{idx_to} )
            : ( $prof->{idx_to}, $prof->{idx_from} );
        next if $lo_idx > $max_idx;  # perfil enteramente futuro
        next if $hi_idx < $off || $lo_idx > $off + $vb;

        $self->_render_one_profile( $canvas, $scale, $prof, $max_idx );
    }
}

sub _render_one_profile {
    my ( $self, $canvas, $scale, $prof, $max_idx ) = @_;

    my $start_idx   = $prof->{idx_from};
    my $start_price = $prof->{price_from};
    my $end_idx     = $prof->{idx_to};
    my $end_price   = $prof->{price_to};
    my $direction   = $prof->{direction};

    if (defined $max_idx) {
        $end_idx = $max_idx if $end_idx > $max_idx;
        $start_idx = $max_idx if $start_idx > $max_idx;
    }

    my $x_start = $scale->index_to_center_x($start_idx);
    my $x_end   = $scale->index_to_center_x($end_idx);
    my $range_  = $end_idx - $start_idx;
    return if $range_ == 0;

    my $bins    = $prof->{bins} || [];
    my $max_vol = $prof->{max_volume} // 0;

    for my $b (@$bins) {
        my $y_start = $start_price + $b->{offset};
        my $y_end   = $end_price   + $b->{offset};

        if ( $self->{show_channel} ) {
            $canvas->createLine(
                $x_start, $scale->value_to_y($y_start),
                $x_end,   $scale->value_to_y($y_end),
                -fill => C_CHANNEL, -width => 1, -tags => [TAG] );
        }

        next unless $self->{show_volume_profile} || $self->{show_poc};
        next if $max_vol <= 0;

        my $k = int( abs($range_) / 100 * $b->{volume_pct} );
        $k = $range_ >= 0 ? $k : -$k;
        my $bar_bar_idx = $start_idx + $k;

        my $fill_price = $direction
            ? $start_price + $b->{slope} * $k
            : $start_price - $b->{slope} * $k;
        my $fill_y = $fill_price + $b->{offset};

        my $is_poc = $b->{is_poc};

        if ( $self->{show_volume_profile} ) {
            my $bar_color = $is_poc
                ? C_POC
                : _gradient_color( $b->{volume}, 0, $max_vol, C_BIN_HIGH, C_BIN_LOW );

            my $x_bar = $scale->index_to_center_x($bar_bar_idx);
            $canvas->createLine(
                $x_bar,   $scale->value_to_y($fill_y),
                $x_start, $scale->value_to_y($y_start),
                -fill => $bar_color, -width => BIN_LINE_WIDTH, -tags => [TAG] );

            $canvas->createText(
                $x_start + 4, $scale->value_to_y($y_start),
                -text   => sprintf( "%.1f%%", $b->{volume_pct} ),
                -fill   => $bar_color,
                -anchor => 'w',
                -font   => [ '', 8 ],
                -tags   => [TAG] );
        }

        if ( $is_poc && $self->{show_poc} ) {
            my $x_end_extended = $scale->index_to_center_x( $end_idx + POC_EXTEND_BARS );
            $canvas->createLine(
                $x_end, $scale->value_to_y($y_end),
                $x_end_extended, $scale->value_to_y($y_end),
                -fill => C_POC, -width => POC_LINE_WIDTH, -tags => [TAG] );

            $canvas->createLine(
                $x_start, $scale->value_to_y($y_start),
                $x_end,   $scale->value_to_y($y_end),
                -fill => C_POC, -width => POC_LINE_WIDTH, -tags => [TAG] );
        }
    }
}

sub _gradient_color {
    my ( $val, $bottom, $top, $color_high, $color_low ) = @_;
    my $range = $top - $bottom;
    $range = 1e-9 if $range == 0;
    my $t = ( $val - $bottom ) / $range;
    $t = 0 if $t < 0;
    $t = 1 if $t > 1;

    my ( $r1, $g1, $b1 ) = _hex_to_rgb($color_low);
    my ( $r2, $g2, $b2 ) = _hex_to_rgb($color_high);

    my $r = int( $r1 + ( $r2 - $r1 ) * $t );
    my $g = int( $g1 + ( $g2 - $g1 ) * $t );
    my $b = int( $b1 + ( $b2 - $b1 ) * $t );

    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

sub _hex_to_rgb {
    my ($hex) = @_;
    $hex =~ s/^#//;
    return ( hex( substr( $hex, 0, 2 ) ), hex( substr( $hex, 2, 2 ) ), hex( substr( $hex, 4, 2 ) ) );
}

1;

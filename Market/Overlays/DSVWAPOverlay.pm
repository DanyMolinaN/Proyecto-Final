package Market::Overlays::DSVWAPOverlay;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Overlays::DSVWAPOverlay
# Responsabilidad: Renderizar los outputs puramente calculados en el
# Market::Concepts::DSVWAP::StateCache de forma desacoplada y eficiente.
# =============================================================================

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
        scale  => $args{scale},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub set_data {
    my ($self, $data) = @_;
    $self->{data} = $data;
    return $self;
}

use constant TAG => 'overlay_dsvwap';

use constant {
    C_VWAP_UP       => 'blue',
    C_VWAP_DOWN     => 'purple',
    C_BAND1         => 'green', # green_40 aprox
    C_BAND2         => 'orange', # orange_30 aprox
    C_BAND3         => 'red',    # red_40 aprox
    C_ZIGZAG_PH     => '#ef5350',
    C_ZIGZAG_PL     => '#26a69a',
    VWAP_WIDTH      => 2,
};

sub draw {
    my ($self, %args) = @_;
    my $canvas = $args{canvas} || $self->{canvas};
    my $scale  = $args{scale}  || $self->{scale};
    my $cache  = $args{data}; # Este es el StateCache
    
    return unless $canvas && $scale && $cache;

    $self->clear($canvas);

    my $settings = $args{settings} || $self->{settings};
    if ($settings && $settings->can('enabled')) {
        return $self unless $settings->enabled('show_dynamic_vwap');
    }

    my $start_idx = $scale->{start_index} // 0;
    my $vb        = $scale->{width} / ($scale->{candle_width} || 8);
    my $end_idx   = $start_idx + $vb;

    # 1. Dibujar Zigzag y Rastro Fantasma
    if (my $lines = $cache->{zigzag_lines}) {
        for my $line (@$lines) {
            # Simple frustum culling
            next if $line->{x2} < $start_idx || $line->{x1} > $end_idx;
            
            my $cx1 = $scale->index_to_center_x($line->{x1});
            my $cy1 = $scale->value_to_y($line->{y1});
            my $cx2 = $scale->index_to_center_x($line->{x2});
            my $cy2 = $scale->value_to_y($line->{y2});
            
            my $color = $line->{dir} == -1 ? C_ZIGZAG_PL : C_ZIGZAG_PH; # Color invertido del swing
            my $dash  = $line->{is_ghost} ? [4, 4] : undef;
            
            $canvas->createLine(
                $cx1, $cy1, $cx2, $cy2,
                -fill => $color,
                -width => 1,
                -tags => [TAG],
                ($dash ? (-dash => $dash) : ()),
            );
        }
    }

    # 1.5. Fantasmas históricos fijos
    if (my $ghosts = $cache->{ghost_levels}) {
        for my $pt (@$ghosts) {
            next if $pt->{x} < $start_idx || $pt->{x} > $end_idx;
            my $cx = $scale->index_to_center_x($pt->{x});
            my $cy = $scale->value_to_y($pt->{y});
            my $tag_id = "ghost_marker_$pt->{x}_$pt->{y}";
            my $lbl = sprintf("👻 %.4f", $pt->{y});
            
            $canvas->createText(
                $cx, $cy - 10,
                -text => $lbl,
                -anchor => 's',
                -fill => '#78909c',
                -font => 'TkDefaultFont 7',
                -tags => [TAG, $tag_id]
            );
        }
    }

    # Ghost Line del Tick (Preview flotante)
    if (my $g_line = $cache->{ghost_line}) {
        my $cx1 = $scale->index_to_center_x($g_line->{x1});
        my $cy1 = $scale->value_to_y($g_line->{y1});
        my $cx2 = $scale->index_to_center_x($g_line->{x2});
        my $cy2 = $scale->value_to_y($g_line->{y2});
        my $color = $g_line->{dir} == -1 ? C_ZIGZAG_PL : C_ZIGZAG_PH;
        
        $canvas->createLine(
            $cx1, $cy1, $cx2, $cy2,
            -fill => $color, -dash => [2, 2], -width => 1, -tags => [TAG]
        );
    }

    # Marcador vivo (Ghost Label)
    if (my $g_lbl = $cache->{ghost_label}) {
        my $cx = $scale->index_to_center_x($g_lbl->{x});
        my $cy = $scale->value_to_y($g_lbl->{y});
        my $color = $g_lbl->{dir} == -1 ? C_ZIGZAG_PL : C_ZIGZAG_PH;
        my $tag_id = "live_ghost_marker";
        
        $canvas->createText(
            $cx, $cy - 10,
            -text => "👻",
            -anchor => 's',
            -fill => $color,
            -font => 'TkDefaultFont 8',
            -tags => [TAG, $tag_id]
        );
    }

    # Rastro acumulado (Ghost Path 1, 2, 3...)
    if (my $path = $cache->{ghost_path}) {
        for my $pt (@$path) {
            next if $pt->{x} < $start_idx || $pt->{x} > $end_idx;
            my $cx = $scale->index_to_center_x($pt->{x});
            my $cy = $scale->value_to_y($pt->{y});
            my $color = $pt->{dir} == -1 ? C_ZIGZAG_PL : C_ZIGZAG_PH;
            my $tag_id = "ghost_path_$pt->{seq}_$pt->{x}";
            
            $canvas->createText(
                $cx, $pt->{dir} == 1 ? $cy + 10 : $cy - 10,
                -text => $pt->{seq},
                -anchor => $pt->{dir} == 1 ? 'n' : 's',
                -fill => $color,
                -font => 'TkDefaultFont 7 bold',
                -tags => [TAG, $tag_id]
            );
        }
    }

    # 2. Dibujar VWAP Principal
    $self->_draw_line($canvas, $scale, $cache->{main_vwap}, VWAP_WIDTH, 1);
    
    # 3. Dibujar Bandas
    $self->_draw_line($canvas, $scale, $cache->{main_bands_u1}, 1, 0, C_BAND1);
    $self->_draw_line($canvas, $scale, $cache->{main_bands_l1}, 1, 0, C_BAND1);
    $self->_draw_line($canvas, $scale, $cache->{main_bands_u2}, 1, 0, C_BAND2);
    $self->_draw_line($canvas, $scale, $cache->{main_bands_l2}, 1, 0, C_BAND2);
    $self->_draw_line($canvas, $scale, $cache->{main_bands_u3}, 1, 0, C_BAND3);
    $self->_draw_line($canvas, $scale, $cache->{main_bands_l3}, 1, 0, C_BAND3);

    # 4. Dibujar Preview VWAP (Ghost)
    if (@{$cache->{ghost_vwap} || []}) {
        $self->_draw_line($canvas, $scale, $cache->{ghost_vwap}, VWAP_WIDTH, 1, undef, [2,2]);
        $self->_draw_line($canvas, $scale, $cache->{ghost_bands_u1}, 1, 0, C_BAND1, [2,2]);
        $self->_draw_line($canvas, $scale, $cache->{ghost_bands_l1}, 1, 0, C_BAND1, [2,2]);
        $self->_draw_line($canvas, $scale, $cache->{ghost_bands_u2}, 1, 0, C_BAND2, [2,2]);
        $self->_draw_line($canvas, $scale, $cache->{ghost_bands_l2}, 1, 0, C_BAND2, [2,2]);
        $self->_draw_line($canvas, $scale, $cache->{ghost_bands_u3}, 1, 0, C_BAND3, [2,2]);
        $self->_draw_line($canvas, $scale, $cache->{ghost_bands_l3}, 1, 0, C_BAND3, [2,2]);
    }

    return $self;
}

sub _draw_line {
    my ($self, $canvas, $scale, $points, $width, $use_dir_color, $force_color, $dash) = @_;
    return unless $points && @$points >= 2;

    my $start_idx = $scale->{start_index} // 0;
    my $vb        = $scale->{width} / ($scale->{candle_width} || 8);
    my $end_idx   = $start_idx + $vb;

    # O(N) filtering per line drawing, could be optimized if chunked, but acceptable for Perl Tk over visible set
    my @visible_pts = grep { $_->{x} >= $start_idx - 1 && $_->{x} <= $end_idx + 1 } @$points;
    return unless @visible_pts >= 2;

    # Si se cambia de direccion, deberiamos dibujar multiples lineas (polyline split).
    # Para simplicidad inicial, unimos todo o dividimos por dir.
    
    my @coords;
    my $current_color = $force_color;
    
    if ($use_dir_color && !$force_color) {
        $current_color = $visible_pts[0]->{dir} == 1 ? C_VWAP_UP : C_VWAP_DOWN;
    }

    for my $pt (@visible_pts) {
        my $cx = $scale->index_to_center_x($pt->{x});
        my $cy = $scale->value_to_y($pt->{y});
        
        # Si el color depende de la direccion y cambia, cerramos la linea y abrimos otra
        if ($use_dir_color && !$force_color) {
            my $c_color = $pt->{dir} == 1 ? C_VWAP_UP : C_VWAP_DOWN;
            if ($c_color ne $current_color && @coords >= 4) {
                # Draw previous chunk
                my @args = (-fill => $current_color, -width => $width, -tags => [TAG]);
                push @args, (-dash => $dash) if $dash;
                $canvas->createLine(@coords, @args);
                
                # Start new chunk beginning with last point to connect them
                @coords = ($coords[-2], $coords[-1], $cx, $cy);
                $current_color = $c_color;
                next;
            }
            $current_color = $c_color;
        }
        
        push @coords, $cx, $cy;
    }
    
    if (@coords >= 4) {
        my @args = (-fill => $current_color, -width => $width, -tags => [TAG]);
        push @args, (-dash => $dash) if $dash;
        $canvas->createLine(@coords, @args);
    }
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas && $canvas->can('delete');
    $canvas->delete(TAG);
    return $self;
}

1;

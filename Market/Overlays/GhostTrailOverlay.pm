package Market::Overlays::GhostTrailOverlay;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Overlays::GhostTrailOverlay
# Responsabilidad: Renderizar los rastros ('1') históricos de los fantasmas.
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

use constant TAG => 'overlay_ghost_trails';

use constant {
    C_ZIGZAG_PH => '#ef5350',
    C_ZIGZAG_PL => '#26a69a',
};

sub draw {
    my ($self, %args) = @_;
    my $canvas = $args{canvas} || $self->{canvas};
    my $scale  = $args{scale}  || $self->{scale};
    my $cache  = $args{data}; 
    
    return unless $canvas && $scale && $cache;

    $self->clear($canvas);

    my $settings = $args{settings} || $self->{settings};
    if ($settings && $settings->can('enabled')) {
        return $self unless $settings->enabled('show_ghost_trails');
    }

    my $start_idx = $scale->{start_index} // 0;
    my $vb        = $scale->{width} / ($scale->{candle_width} || 8);
    my $end_idx   = $start_idx + $vb;

    if (my $trails = $cache->{ghost_trails}) {
        for my $pt (@$trails) {
            # Solo los que están en pantalla
            next if $pt->{x_last} < $start_idx || $pt->{x_last} > $end_idx;
            
            my $cx = $scale->index_to_center_x($pt->{x_last});
            my $cy = $scale->value_to_y($pt->{y_last});
            
            # El color es invertido al swing, igual que en GhostEngine original
            my $color = $pt->{ghost_dir} == -1 ? C_ZIGZAG_PL : C_ZIGZAG_PH;
            
            # Etiqueta "1" en color texto miss_pl_css / miss_ph_css y sin recuadro.
            $canvas->createText(
                $cx, $pt->{ghost_dir} == 1 ? $cy + 10 : $cy - 10,
                -text => '1',
                -anchor => $pt->{ghost_dir} == 1 ? 'n' : 's',
                -fill => $color,
                -font => 'TkDefaultFont 7',
                -tags => [TAG]
            );
        }
    }

    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas && $canvas->can('delete');
    $canvas->delete(TAG);
    return $self;
}

1;

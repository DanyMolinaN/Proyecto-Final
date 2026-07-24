package Market::Overlays::OrderBlockOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data => undef,
        canvas => $args{canvas},
        scale => $args{scale},
        elements => [],
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

sub draw {
    my ($self, %args) = @_;
    my $canvas    = $args{canvas} || $self->{canvas};
    my $scale     = $args{scale}  || $self->{scale};
    my $data      = $args{data}   || $self->{data};
    my $start_idx = $args{start_idx};
    my $end_idx   = $args{end_idx};
    return unless $canvas && $scale;
    return unless $data;

    my $settings = $args{settings} || $self->{settings};
    my $show_ext = 1;
    my $show_int = 1;
    if ($settings && $settings->can('enabled')) {
        $show_ext = $settings->enabled('show_ob_external') ? 1 : 0;
        $show_int = $settings->enabled('show_ob_internal') ? 1 : 0;
        return $self unless $show_ext || $show_int;
    }

    $self->clear($canvas);
    my $blocks = $data->{blocks} || [];
    return $self unless ref($blocks) eq 'ARRAY';

    my $total_received     = scalar(@$blocks);
    my $discarded_invalid  = 0;
    my $discarded_viewport = 0;
    my $discarded_invalidated = 0;
    my $discarded_scope    = 0;
    my $discarded_count    = 0;
    my $rendered           = 0;
    my $rendered_mitigated = 0;

    # LuxAlgo: conservar solo los N OB más recientes por scope (por break_index).
    my $ext_count = 5;
    my $int_count = 5;
    if ($settings && $settings->can('values')) {
        my $vals = $settings->values() || {};
        $ext_count = $vals->{ob_external_count} if defined $vals->{ob_external_count};
        $int_count = $vals->{ob_internal_count} if defined $vals->{ob_internal_count};
        $ext_count = 5 unless defined $ext_count && $ext_count =~ /^\d+$/;
        $int_count = 5 unless defined $int_count && $int_count =~ /^\d+$/;
        $ext_count = 0 + $ext_count;
        $int_count = 0 + $int_count;
    }

    # Prefiltro: scope + no Invalidated. Luego keep-N por scope (sin tocar el engine).
    my (@ext_pool, @int_pool);
    for my $block (@$blocks) {
        next unless $block && ref($block) eq 'HASH';
        my $state = $block->{state} || 'Detected';
        if ($state eq 'Invalidated') {
            $discarded_invalidated++;
            next;
        }
        my $scope = $block->{scope} // 'swing';
        $scope = 'external' if $scope eq 'swing';
        if ($scope eq 'internal') {
            unless ($show_int) { $discarded_scope++; next; }
            push @int_pool, $block;
        }
        else {
            unless ($show_ext) { $discarded_scope++; next; }
            push @ext_pool, $block;
        }
    }

    my $ext_before = scalar(@ext_pool);
    my $int_before = scalar(@int_pool);
    @ext_pool = _keep_recent_obs(\@ext_pool, $ext_count);
    @int_pool = _keep_recent_obs(\@int_pool, $int_count);
    $discarded_count += ($ext_before - scalar(@ext_pool)) + ($int_before - scalar(@int_pool));

    my @to_draw = (@ext_pool, @int_pool);

    # Ancho de vela: usar el campo directo del scale si existe
    my $cw = ($scale->{candle_width} || 0);
    if ($cw <= 0) {
        eval {
            my $x0 = $scale->index_to_center_x(0);
            my $x1 = $scale->index_to_center_x(1);
            $cw = abs($x1 - $x0) if defined $x0 && defined $x1;
        };
        $cw ||= 8;
    }
    my $half = $cw / 2;

    # Límite derecho visible para extender los bloques activos
    my $view_right = $end_idx // (($start_idx // 0) + 300);

    for my $block (@to_draw) {
        next unless $block && ref($block) eq 'HASH';

        my $state = $block->{state} || 'Detected';

        my $idx   = $block->{index} // $block->{created_index};
        my $price = $block->{price} // $block->{value};
        my $type  = $block->{type};
        unless (defined $idx && defined $price && defined $type) {
            $discarded_invalid++;
            next;
        }

        # Un bloque que empieza antes del viewport puede seguir visible
        # si su extremo derecho solapa la ventana.
        my $block_end = $block->{invalidated_index}
                     // $block->{mitigated_index}
                     // $view_right;
        if (defined $start_idx && $block_end < $start_idx) {
            $discarded_viewport++;
            next;
        }
        if (defined $end_idx && $idx > $end_idx) {
            $discarded_viewport++;
            next;
        }

        my $is_mitigated = ($state eq 'Mitigated');
        my $label = $type eq 'bullish' ? 'OB+' : $type eq 'bearish' ? 'OB-' : 'OB';

        # Colores: bullish=verde, bearish=rojo; mitigados más tenues
        my ($fill_color, $outline_color);
        if ($type eq 'bearish') {
            $fill_color    = $is_mitigated ? '#8b2020' : '#ef5350';
            $outline_color = $is_mitigated ? '#7a1a1a' : '#ff5252';
        } else {
            $fill_color    = $is_mitigated ? '#1b5e20' : '#2e7d32';
            $outline_color = $is_mitigated ? '#1a4a1a' : '#4caf50';
        }

        # X inicio: borde izquierdo de la vela OB
        my $x1 = eval { $scale->index_to_center_x($idx) - $half };
        next unless defined $x1;

        # X fin: activos llegan al borde visible; mitigados hasta donde fueron tocados
        my $draw_end;
        if ($is_mitigated) {
            $draw_end = $block->{mitigated_index} // $view_right;
            $draw_end = $view_right if $draw_end > $view_right;
        } else {
            $draw_end = $view_right;
        }
        my $x2 = eval { $scale->index_to_center_x($draw_end) + $half };
        next unless defined $x2;
        $x2 = $x1 + ($half * 2) if $x2 <= $x1;

        my $high = $block->{high} // $price;
        my $low  = $block->{low}  // $price;
        my $y1   = eval { $scale->value_to_y($high) };
        my $y2   = eval { $scale->value_to_y($low)  };
        next unless defined $y1 && defined $y2;
        ($y1, $y2) = ($y2, $y1) if $y1 > $y2;

        # Stipple: activos más densos (gray50), mitigados más transparentes (gray25)
        my $stipple = $is_mitigated ? 'gray25' : 'gray50';

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $fill_color,
            -stipple => $stipple,
            -outline => $outline_color,
            -width   => 1,
            -tags    => ['overlay_order_block'],
        );

        # Etiqueta solo si la zona tiene altura suficiente
        my $zone_h = abs($y2 - $y1);
        if ($zone_h >= 8) {
            my $y_mid   = ($y1 + $y2) / 2;
            my $lbl_txt = $is_mitigated
                ? "$label " . ($block->{mitigation_pct} // 0) . "%"
                : $label;
            $canvas->createText($x1 + 4, $y_mid,
                -text   => $lbl_txt,
                -anchor => 'w',
                -fill   => $outline_color,
                -font   => 'Helvetica 7 bold',
                -tags   => ['overlay_order_block'],
            );
        }

        if ($is_mitigated) { $rendered_mitigated++; }
        else                { $rendered++;           }
    }

    $self->{smc_audit} = {
        total_received        => $total_received,
        discarded_by_viewport => $discarded_viewport,
        discarded_invalid     => $discarded_invalid,
        discarded_invalidated => $discarded_invalidated,
        discarded_by_scope    => $discarded_scope,
        discarded_by_count    => $discarded_count,
        rendered              => $rendered + $rendered_mitigated,
        rendered_active       => $rendered,
        rendered_mitigated    => $rendered_mitigated,
        ob_external_count     => $ext_count,
        ob_internal_count     => $int_count,
    };

    return $self;
}

# Conserva los $max OB más recientes por break_index (LuxAlgo Swing/Internal OB Count).
# No modifica el engine: solo el conjunto a dibujar.
sub _keep_recent_obs {
    my ($blocks, $max) = @_;
    return () unless $blocks && ref($blocks) eq 'ARRAY' && @$blocks;
    return @$blocks unless defined $max && $max > 0 && @$blocks > $max;

    my @sorted = sort {
        ($b->{break_index} // $b->{confirmation_index} // $b->{index} // 0)
            <=>
        ($a->{break_index} // $a->{confirmation_index} // $a->{index} // 0)
    } @$blocks;
    @sorted = @sorted[0 .. $max - 1];
    return sort {
        ($a->{break_index} // $a->{confirmation_index} // $a->{index} // 0)
            <=>
        ($b->{break_index} // $b->{confirmation_index} // $b->{index} // 0)
    } @sorted;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_order_block') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    return $self;
}

1;

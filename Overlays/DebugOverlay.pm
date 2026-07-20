package Market::Overlays::DebugOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data    => undef,
        canvas  => $args{canvas},
        scale   => $args{scale},
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
    my $canvas = $args{canvas} || $self->{canvas};
    my $data   = $args{data}   || $self->{data};
    return unless $canvas;

    $self->clear($canvas);
    return $self unless $data && ref($data) eq 'HASH';

    my $x = 12;
    my $y = 104;
    my $line_height = 12;
    my @lines;

    push @lines, 'DEBUG OVERLAY';
    push @lines, sprintf('TF: %s   SCALE: %s', $data->{runtime}->{active_tf} // '-', $data->{runtime}->{auto_scale} // '-');
    push @lines, sprintf('VISIBLE: %s   START: %s   END: %s', $data->{runtime}->{visible_bars} // '-', $data->{runtime}->{start_idx} // '-', $data->{runtime}->{end_idx} // '-');
    push @lines, sprintf('VIEW_START: %s   X_SHIFT: %.2f', $data->{runtime}->{view_start} // '-', $data->{runtime}->{x_shift} // 0);
    push @lines, sprintf('CROSSHAIR IDX: %s', defined $data->{runtime}->{crosshair_idx} ? $data->{runtime}->{crosshair_idx} : 'NONE');
    push @lines, sprintf('REPLAY: %s   MARKET_SIZE: %s', $data->{runtime}->{replay_enabled} // 'no', $data->{runtime}->{market_size} // '-');
    push @lines, '';
    push @lines, sprintf('VOL PROFILE BINS: %s', $data->{overlay_counts}->{volume_profile} // 0);
    push @lines, sprintf('ANCH VWAP: %s', $data->{overlay_counts}->{anchored_vwap} // 0);
    push @lines, sprintf('LIQUIDITY LEVELS: %s', $data->{overlay_counts}->{liquidity} // 0);
    push @lines, sprintf('STRUCTURE POINTS: %s', $data->{overlay_counts}->{structure} // 0);
    push @lines, sprintf('FVG GAPS: %s', $data->{overlay_counts}->{fvg} // 0);
    push @lines, sprintf('ORDER BLOCKS: %s', $data->{overlay_counts}->{order_block} // 0);
    push @lines, sprintf('ACTIVE OVERLAYS: %s', join(', ', @{ $data->{active_overlays} || [] }));

    for my $line (@lines) {
        $canvas->createText($x, $y,
            -text   => $line,
            -anchor => 'nw',
            -fill   => '#ffffff',
            -font   => 'Helvetica 8',
            -tags   => ['overlay_debug'],
        );
        $y += $line_height;
    }

    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas && $canvas->can('delete');
    $canvas->delete('overlay_debug');
    $self->{elements} = [];
    return $self;
}

1;

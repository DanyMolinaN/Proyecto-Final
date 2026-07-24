package Market::Overlays::ZZMTFOverlay;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

require 'Market/Overlays/StructureOverlay/ZigZag.pm';

sub new {
    my ($class, %args) = @_;
    my $self = {
        data            => undef,
        canvas          => $args{canvas},
        scale           => $args{scale},
        settings        => $args{settings},
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
    my $canvas      = $args{canvas} || $self->{canvas};
    my $scale       = $args{scale}  || $self->{scale};
    my $data        = $args{data}   || $self->{data};
    return unless $canvas && $scale;
    return unless $data && ref($data) eq 'HASH';

    $self->clear($canvas);

    my $settings = $self->{settings};
    my $internal_swings = $data->{internal_swings} || [];
    my $external_swings = $data->{external_swings} || [];
    my $tentative_in = $data->{tentative_in};
    my $tentative_ex = $data->{tentative_ex};

    if (_enabled($settings, 'show_zzmtf_internal')) {
        Market::Overlays::StructureOverlay::_draw_zigzag(
            $canvas, $scale, $internal_swings,
            $tentative_in,
            '#e84545', 2, [4, 4], 'overlay_zzmtf_internal',
        );
    }
    if (_enabled($settings, 'show_zzmtf_external')) {
        Market::Overlays::StructureOverlay::_draw_zigzag(
            $canvas, $scale, $external_swings,
            $tentative_ex,
            '#903749', 3, undef, 'overlay_zzmtf_external',
        );
    }

    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    if ( $canvas && $canvas->can('delete') ) {
        $canvas->delete('overlay_zzmtf_internal');
        $canvas->delete('overlay_zzmtf_external');
    }
    return $self;
}

sub _enabled {
    my ($settings, $key) = @_;
    return 1 unless $settings && $settings->can('enabled');
    return $settings->enabled($key);
}

1;

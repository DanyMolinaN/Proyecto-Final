package Market::Volume::VolumeProfileEngine;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Volume::SessionProfile;

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
    };
    $self->{session_profile} = $self->{session_profile} || Market::Volume::SessionProfile->new(
        bin_size         => $args{bin_size},
        percentage       => $args{percentage},
        threshold_factor => $args{threshold_factor},
    );
    bless $self, $class;
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $result = $self->{session_profile}->calculate(
        $market_data,
        replay_controller => $args{replay_controller},
        timeframe         => $args{timeframe},
        start_index       => $args{start_index},
        end_index         => $args{end_index},
    );

    return $result;
}

sub session_profile { my ($self) = @_; return $self->{session_profile}; }

1;

package Market::Volume::TimePersistenceEngine;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Volume::TimePersistenceProfile;

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
    };
    $self->{session_profile} = $self->{session_profile} || Market::Volume::TimePersistenceProfile->new(
        bin_size         => $args{bin_size},
        percentage       => $args{percentage},
        threshold_factor => $args{threshold_factor},
    );
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{session_profile}->reset() if $self->{session_profile} && $self->{session_profile}->can('reset');
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $result = $self->{session_profile}->calculate(
        $market_data,
        replay_controller => $args{replay_controller},
        timeframe         => $args{timeframe},
        start_index       => $args{view_start} // $args{start_index},
        end_index         => $args{view_end}   // $args{end_index},
    );

    return $result;
}

sub session_profile { my ($self) = @_; return $self->{session_profile}; }

1;

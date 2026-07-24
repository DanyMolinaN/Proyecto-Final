package Market::Core::ReplayController;

# =============================================================================
# Market::Core::ReplayController
# =============================================================================
# Controlador de replay: simula el mercado vela a vela sin filtrar velas futuras.
# Controles: enter, play, pause, step +/-, fast forward, exit.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        initialized   => 0,
        enabled       => 0,
        playing       => 0,
        paused        => 1,
        speed         => $args{speed} || 1,
        current_index => 0,
        limit_index   => undef,
        mode          => 'idle',
        position      => 0,
        %args,
    };
    bless $self, $class;
    return $self;
}

sub initialize {
    my ($self) = @_;
    $self->{initialized} = 1;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{enabled}       = 0;
    $self->{playing}       = 0;
    $self->{paused}        = 1;
    $self->{speed}         = 1;
    $self->{current_index} = 0;
    $self->{limit_index}   = undef;
    $self->{mode}          = 'idle';
    $self->{position}      = 0;
    return $self;
}

sub dispose {
    my ($self) = @_;
    $self->{initialized} = 0;
    $self->{enabled}     = 0;
    $self->{mode}        = 'disposed';
    $self->{position}    = 0;
    return $self;
}

sub is_initialized {
    my ($self) = @_;
    return $self->{initialized} ? 1 : 0;
}

sub is_active {
    my ($self) = @_;
    return $self->{enabled} ? 1 : 0;
}

sub set_mode {
    my ($self, $mode) = @_;
    $self->{mode} = defined $mode ? $mode : 'idle';
    return $self->{mode};
}

sub _sync_limit {
    my ($self) = @_;
    $self->{limit_index} = $self->{current_index};
    $self->{position}    = $self->{current_index};
    return $self->{limit_index};
}

# enter_replay($index, $total) -> $index
# Activa replay en el indice dado (ultima vela visible hasta ese punto).
sub enter_replay {
    my ($self, $index, $total) = @_;
    $total = 0 unless defined $total && $total > 0;
    $index = 0 unless defined $index;
    $index = 0            if $index < 0;
    $index = $total - 1   if $total > 0 && $index >= $total;

    $self->{enabled}       = 1;
    $self->{playing}       = 0;
    $self->{paused}        = 1;
    $self->{current_index} = $index;
    $self->{mode}          = 'replay';
    $self->_sync_limit();
    return $self->{current_index};
}

# exit_replay() -> 1
sub exit_replay {
    my ($self) = @_;
    $self->reset();
    return 1;
}

sub pause {
    my ($self) = @_;
    $self->{playing} = 0;
    $self->{paused}  = 1;
    return 1;
}

sub play {
    my ($self) = @_;
    return 0 unless $self->{enabled};
    $self->{playing} = 1;
    $self->{paused}  = 0;
    return 1;
}

sub toggle_play {
    my ($self) = @_;
    return 0 unless $self->{enabled};
    if ($self->{playing}) {
        return $self->pause();
    }
    return $self->play();
}

sub stop {
    my ($self) = @_;
    $self->{playing} = 0;
    $self->{paused}  = 1;
    return 1;
}

sub set_speed {
    my ($self, $speed) = @_;
    $speed = 1 unless defined $speed && $speed > 0;
    $self->{speed} = $speed + 0;
    return $self->{speed};
}

sub set_current_index {
    my ($self, $index) = @_;
    return 0 unless defined $index;
    $self->{current_index} = $index + 0;
    $self->_sync_limit();
    return $self->{current_index};
}

sub start {
    my ($self, $index, $total) = @_;
    if (defined $index) {
        $self->enter_replay($index, $total);
    }
    else {
        $self->{enabled} = 1;
        $self->_sync_limit();
    }
    $self->{playing} = 1;
    $self->{paused}  = 0;
    return 1;
}

sub resume {
    my ($self) = @_;
    return $self->play();
}

sub step_forward {
    my ($self, $total) = @_;
    return 0 unless $self->{enabled};
    my $max = (defined $total && $total > 0) ? ($total - 1) : $self->{current_index} + 1;
    return $self->{current_index} if $self->{current_index} >= $max;
    $self->{current_index} += 1;
    $self->_sync_limit();
    return $self->{current_index};
}

sub step_backward {
    my ($self) = @_;
    return 0 unless $self->{enabled};
    $self->{current_index} -= 1 if $self->{current_index} > 0;
    $self->_sync_limit();
    return $self->{current_index};
}

sub fast_forward {
    my ($self, $steps, $total) = @_;
    $steps = 5 unless defined $steps && $steps > 0;
    my $last = $self->{current_index};
    for (1 .. $steps) {
        my $idx = $self->step_forward($total);
        $last = $idx;
        last if defined $total && $total > 0 && $idx >= $total - 1;
    }
    return $last;
}

sub seek {
    my ($self, $index, $total) = @_;
    return 0 unless defined $index;
    $index = 0 if $index < 0;
    if (defined $total && $total > 0 && $index >= $total) {
        $index = $total - 1;
    }
    $self->{current_index} = $index + 0;
    $self->_sync_limit();
    return $self->{current_index};
}

# visible_limit($total) -> $index | undef
# Indice de la ultima vela visible durante replay. undef si replay inactivo.
sub visible_limit {
    my ($self, $total) = @_;
    return undef unless $self->{enabled};
    return undef unless defined $total && $total > 0;

    my $limit = defined $self->{limit_index}
        ? $self->{limit_index}
        : $self->{current_index};
    return undef unless defined $limit;
    $limit = $total - 1 if $limit > $total - 1;
    $limit = 0            if $limit < 0;
    return $limit;
}

sub get_state {
    my ($self) = @_;
    return {
        initialized   => $self->{initialized},
        enabled       => $self->{enabled},
        playing       => $self->{playing},
        paused        => $self->{paused},
        speed         => $self->{speed},
        mode          => $self->{mode},
        position      => $self->{position},
        current_index => $self->{current_index},
        limit_index   => $self->{limit_index},
    };
}

1;

use strict;
use warnings;

use Test::More tests => 2;
use_ok 'APIProxy';
like( $APIProxy::VERSION, qr/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/,
    'Application release version uses SemVer MAJOR.MINOR.PATCH' );

use strict;
use warnings;

use APIProxy;
use Test::More tests => 4;
use Plack::Test;
use HTTP::Request::Common;
use Ref::Util qw<is_coderef>;

my $app = APIProxy->to_app;
ok( is_coderef($app), 'Got app' );

my $test = Plack::Test->create($app);
my $res  = $test->request( GET '/gmap_search?q=Perl' );

ok( $res->is_success, '[GET /gmap_search?q=Perl] successful' );
is( $res->code, 200, 'Response code is 200' );
is( $res->content_type, 'text/html', 'Content-Type is text/html' );

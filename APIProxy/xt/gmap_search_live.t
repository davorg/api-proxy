use strict;
use warnings;

use Test::More;

plan skip_all => 'Set API_PROXY_LIVE_TESTS=1 to enable real Google requests'
    unless ($ENV{API_PROXY_LIVE_TESTS} // '') eq '1';
BAIL_OUT('GOOGLE_MAPS_API_KEY is required for the live smoke test')
    unless $ENV{GOOGLE_MAPS_API_KEY};

require APIProxy;
require Plack::Test;
require HTTP::Request::Common;

# Exercise the provider without reading or populating a deployment's cache.
APIProxy::set(plugins => {
    'Cache::CHI' => { driver => 'Memory', global => 0 },
});

my $test = Plack::Test->create(APIProxy->to_app);
my $res = $test->request(HTTP::Request::Common::GET('/gmap_search?q=Clapham+Common'));

is( $res->code, 200, 'Live Google Maps request succeeds' );
is( $res->content_type, 'text/html', 'Live response is HTML' );
like( $res->content, qr/<html\b/i, 'Live response contains an HTML document' );

done_testing;

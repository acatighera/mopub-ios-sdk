#import "MPInterstitialAdController.h"
#import "MPAdConfigurationFactory.h"
#import "FakeMPAdServerCommunicator.h"
#import "FakeGADInterstitial.h"
#import "GADRequest.h"

using namespace Cedar::Matchers;
using namespace Cedar::Doubles;

SPEC_BEGIN(MPGoogleAdMobIntegrationSuite)

describe(@"MPGoogleAdMobIntegrationSuite", ^{
    __block id<MPInterstitialAdControllerDelegate, CedarDouble> delegate;
    __block MPInterstitialAdController *interstitial = nil;
    __block UIViewController *presentingController;
    __block FakeGADInterstitial *fakeGADInterstitial;
    __block FakeMPAdServerCommunicator *communicator;
    __block MPAdConfiguration *configuration;
    __block GADRequest<CedarDouble> *fakeGADRequest;

    beforeEach(^{
        delegate = nice_fake_for(@protocol(MPInterstitialAdControllerDelegate));

        interstitial = [MPInterstitialAdController interstitialAdControllerForAdUnitId:@"admob_interstitial"];
        interstitial.location = [[[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(37.1, 21.2)
                                                               altitude:11
                                                     horizontalAccuracy:12.3
                                                       verticalAccuracy:10
                                                              timestamp:[NSDate date]] autorelease];
        interstitial.delegate = delegate;

        presentingController = [[[UIViewController alloc] init] autorelease];

        // request an Ad
        [interstitial loadAd];
        communicator = fakeProvider.lastFakeMPAdServerCommunicator;
        communicator.loadedURL.absoluteString should contain(@"admob_interstitial");

        // prepare the fake and tell the injector about it
        fakeGADInterstitial = [[[FakeGADInterstitial alloc] init] autorelease];
        fakeProvider.fakeGADInterstitial = fakeGADInterstitial.masquerade;
        fakeGADRequest = nice_fake_for([GADRequest class]);
        fakeProvider.fakeGADRequest = fakeGADRequest;

        // receive the configuration -- this will create an adapter which will use our fake interstitial
        NSDictionary *headers = @{kInterstitialAdTypeHeaderKey: @"admob_full",
                                  kNativeSDKParametersHeaderKey:@"{\"adUnitID\":\"g00g1e\"}"};
        configuration = [MPAdConfigurationFactory defaultInterstitialConfigurationWithHeaders:headers HTMLString:nil];
        [communicator receiveConfiguration:configuration];

        // clear out the communicator so we can make future assertions about it
        [communicator resetLoadedURL];

        setUpInterstitialSharedContext(communicator, delegate, interstitial, @"admob_interstitial", fakeGADInterstitial, configuration.failoverURL);
    });

    it(@"should set up the google ad request correctly", ^{
        fakeGADInterstitial.adUnitID should equal(@"g00g1e");
        fakeGADRequest should have_received(@selector(setLocationWithLatitude:longitude:accuracy:)).with(37.1f).and_with(21.2f).and_with(12.3f);
    });

    context(@"while the ad is loading", ^{
        beforeEach(^{
            fakeGADInterstitial.loadedRequest should_not be_nil;
        });

        it(@"should not tell the delegate anything, nor should it be ready", ^{
            delegate.sent_messages should be_empty;
            interstitial.ready should equal(NO);
        });

        context(@"and the user tries to load again", ^{ itShouldBehaveLike(anInterstitialThatPreventsLoading); });
        context(@"and the user tries to show the ad", ^{ itShouldBehaveLike(anInterstitialThatPreventsShowing); });
        context(@"and the timeout interval elapses", ^{ itShouldBehaveLike(anInterstitialThatTimesOut); });
    });

    context(@"when the ad successfully loads", ^{
        beforeEach(^{
            [delegate reset_sent_messages];
            [fakeGADInterstitial simulateLoadingAd];
        });

        it(@"should tell the delegate and -ready should return YES", ^{
            verify_fake_received_selectors(delegate, @[@"interstitialDidLoadAd:"]);
            interstitial.ready should equal(YES);
        });

        context(@"and the user tries to load again", ^{ itShouldBehaveLike(anInterstitialThatHasAlreadyLoaded); });
        context(@"and the timeout interval elapses", ^{ itShouldBehaveLike(anInterstitialThatDoesNotTimeOut); });

        context(@"and the user shows the ad", ^{
            beforeEach(^{
                [delegate reset_sent_messages];
                fakeProvider.sharedFakeMPAnalyticsTracker.trackedImpressionConfigurations.count should equal(0);
                [interstitial showFromViewController:presentingController];
            });

            it(@"should track an impression and tell AdMob to show", ^{
                verify_fake_received_selectors(delegate, @[@"interstitialWillAppear:", @"interstitialDidAppear:"]);
                fakeGADInterstitial.presentingViewController should equal(presentingController);
                fakeProvider.sharedFakeMPAnalyticsTracker.trackedImpressionConfigurations.count should equal(1);
            });

            context(@"when the user interacts with the ad", ^{
                beforeEach(^{
                    [delegate reset_sent_messages];
                });

                it(@"should track only one click, no matter how many interactions there are, and shouldn't tell the delegate anything", ^{
                    [fakeGADInterstitial simulateUserInteraction];
                    fakeProvider.sharedFakeMPAnalyticsTracker.trackedClickConfigurations.count should equal(1);
                    [fakeGADInterstitial simulateUserInteraction];
                    fakeProvider.sharedFakeMPAnalyticsTracker.trackedClickConfigurations.count should equal(1);

                    delegate.sent_messages should be_empty;
                });
            });

            context(@"and the user tries to load again", ^{ itShouldBehaveLike(anInterstitialThatHasAlreadyLoaded); });

            context(@"and the user tries to show (again)", ^{
                __block UIViewController *newPresentingController;

                beforeEach(^{
                    [delegate reset_sent_messages];
                    [fakeProvider.sharedFakeMPAnalyticsTracker reset];

                    newPresentingController = [[[UIViewController alloc] init] autorelease];
                    [interstitial showFromViewController:newPresentingController];
                });

                it(@"should tell AdMob to show and send the delegate messages again", ^{
                    // XXX: The "ideal" behavior here is to ignore any -show messages after the first one, until the
                    // underlying ad is dismissed. However, given the risk that some third-party or custom event
                    // network could give us a silent failure when presenting (and therefore never dismiss), it might
                    // be best just to allow multiple calls to go through.

                    fakeGADInterstitial.presentingViewController should equal(newPresentingController);
                    verify_fake_received_selectors(delegate, @[@"interstitialWillAppear:", @"interstitialDidAppear:"]);
                    fakeProvider.sharedFakeMPAnalyticsTracker.trackedImpressionConfigurations.count should equal(0);
                });
            });

            context(@"when the ad is dismissed", ^{
                beforeEach(^{
                    [delegate reset_sent_messages];
                    [fakeGADInterstitial simulateUserDismissingAd];
                });

                it(@"should tell the delegate and should no longer be ready", ^{
                    verify_fake_received_selectors(delegate, @[@"interstitialWillDisappear:", @"interstitialDidDisappear:"]);
                    interstitial.ready should equal(NO);
                });

                context(@"and the user tries to load again", ^{ itShouldBehaveLike(anInterstitialThatStartsLoadingAnAdUnit); });
                context(@"and the user tries to show the ad", ^{ itShouldBehaveLike(anInterstitialThatPreventsShowing); });
            });
        });
    });

    context(@"when the ad fails to load", ^{
        beforeEach(^{
            [delegate reset_sent_messages];
            [fakeGADInterstitial simulateFailingToLoad];
        });

        itShouldBehaveLike(anInterstitialThatLoadsTheFailoverURL);
        context(@"and the timeout interval elapses", ^{ itShouldBehaveLike(anInterstitialThatDoesNotTimeOut); });
    });
});

SPEC_END

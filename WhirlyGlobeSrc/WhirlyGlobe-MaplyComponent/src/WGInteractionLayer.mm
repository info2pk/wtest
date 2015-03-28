/*
 *  WGInteractionLayer_private.h
 *  WhirlyGlobeComponent
 *
 *  Created by Steve Gifford on 7/21/12.
 *  Copyright 2011-2013 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "WGInteractionLayer_private.h"
#import "MaplyBaseInteractionLayer_private.h"
#import "MaplyScreenMarker.h"
#import "MaplyMarker.h"
#import "MaplyScreenLabel.h"
#import "MaplyLabel.h"
#import "MaplyVectorObject_private.h"
#import "MaplyShape.h"
#import "MaplySticker.h"
#import "WGCoordinate.h"

using namespace Eigen;
using namespace WhirlyKit;
using namespace WhirlyGlobe;

@implementation WGInteractionLayer
{
    AnimateViewMomentum *autoSpinner;
}

// Initialize with the globeView
-(id)initWithGlobeView:(WhirlyGlobeView *)inGlobeView
{
    self = [super initWithView:inGlobeView];
    if (!self)
        return nil;
    globeView = inGlobeView;
    
    return self;
}

- (void)startWithThread:(WhirlyKitLayerThread *)inLayerThread scene:(WhirlyKit::Scene *)inScene
{
    [super startWithThread:inLayerThread scene:inScene];
        
    // Run the auto spin every so often
    [self performSelector:@selector(processAutoSpin:) withObject:nil afterDelay:1.0];
}

/// Called by the layer thread to shut a layer down.
/// Clean all your stuff out of the scenegraph and so forth.
- (void)shutdown
{
    [super shutdown];
}

- (void)setAutoRotateInterval:(float)inAutoRotateInterval degrees:(float)inAutoRotateDegrees
{
    autoRotateInterval = inAutoRotateInterval;
    autoRotateDegrees = inAutoRotateDegrees;
    if (autoSpinner)
    {
        if (autoRotateInterval == 0.0 || autoRotateDegrees == 0)
        {
            [globeView cancelAnimation];
            autoSpinner = nil;
        } else
            // Update the spin
            autoSpinner.velocity = autoRotateDegrees / 180.0 * M_PI;
    }
}

// Try to auto-spin every so often
-(void)processAutoSpin:(id)sender
{
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    
    if (autoSpinner && globeView.delegate != autoSpinner)
        autoSpinner = nil;
    
    if (autoRotateInterval > 0.0 && !autoSpinner)
    {
        if (now - globeView.lastChangedTime > autoRotateInterval &&
            now - lastTouched > autoRotateInterval)
        {
            float anglePerSec = autoRotateDegrees / 180.0 * M_PI;
            
            // Keep going in that direction
            Vector3f upVector(0,0,1);
            autoSpinner = [[AnimateViewMomentum alloc] initWithView:globeView velocity:anglePerSec accel:0.0 axis:upVector northUp:false];
            globeView.delegate = autoSpinner;
        }
    }
    
    [self performSelector:@selector(processAutoSpin:) withObject:nil afterDelay:1.0];
}

- (bool) screenPtFromGeo:(Point2f)geoPt ret:(Point2f &)screenPt placeInfo:(SelectionManager::PlacementInfo &)pInfo
{
    Point3d pt = visualView.coordAdapter->localToDisplay(visualView.coordAdapter->getCoordSystem()->geographicToLocal3d(GeoCoord(geoPt.x(),geoPt.y())));
    
    if (CheckPointAndNormFacing(pt,pt.normalized(),pInfo.viewAndModelMat,pInfo.viewModelNormalMat) < 0.0)
        return false;
    
    CGPoint cgScreenPt =  [globeView pointOnScreenFromSphere:pt transform:&pInfo.viewAndModelMat frameSize:Point2f(layerThread.renderer.framebufferWidth/self.glView.contentScaleFactor,layerThread.renderer.framebufferHeight/self.glView.contentScaleFactor)];
    screenPt = Point2f(cgScreenPt.x,cgScreenPt.y);
    
    return true;
}

// Minimum distance from touch point to vector object in screen space
- (double) dist2Squared:(MaplyVectorObject *)vecObj within:(double)screenDist touch:(const Point2f &)touchPt placeInfo:(SelectionManager::PlacementInfo &)pInfo
{
    double closeDist2 = MAXFLOAT;
    
    for (ShapeSet::iterator it = vecObj.shapes.begin();it != vecObj.shapes.end();++it)
    {
        VectorArealRef areal = boost::dynamic_pointer_cast<VectorAreal>(*it);
        if (areal)
        {
            for (unsigned int ri=0;ri<areal->loops.size(); ri++)
            {
                VectorRing &ring = areal->loops[ri];
                for (unsigned int ii=0;ii<ring.size();ii++)
                {
                    Point2f &p0 = ring[ii];
                    Point2f &p1 = ring[(ii+1)%ring.size()];
                    
                    Point2f sp0,sp1;
                    if ([self screenPtFromGeo:p0 ret:sp0 placeInfo:pInfo] && [self screenPtFromGeo:p1 ret:sp1 placeInfo:pInfo])
                    {
                        float t;
                        Point2f closePt = ClosestPointOnLineSegment(sp0,sp1,touchPt,t);
                        float dist2 = (closePt-touchPt).squaredNorm();
                        if (dist2 < closeDist2)
                            closeDist2 = dist2;
                    }
                }
            }
        } else {
            VectorLinearRef lin = boost::dynamic_pointer_cast<VectorLinear>(*it);
            if (lin)
            {
                
            } else {
                VectorPointsRef pt = boost::dynamic_pointer_cast<VectorPoints>(*it);
                if (pt)
                {
                    
                }
                // Note: Ignoring triangles
            }
        }
    }
    
    return closeDist2;
}

- (NSArray *)findVectorsNearScreenPt:(WhirlyKit::Point2f)screenPt geoPt:(WhirlyKit::Point2f)geoPt screenDist:(double)screenDist multi:(bool)multi
{
    NSMutableArray *foundObjs = [NSMutableArray array];

    SelectionManager::PlacementInfo pInfo(visualView,layerThread.renderer);
    geoPt = [visualView unwrapCoordinate:geoPt];
    
    @synchronized(userObjects)
    {
        for (MaplyComponentObject *userObj in userObjects)
        {
            if (userObj.vectors && userObj.isSelectable && userObj.enable)
            {
                for (MaplyVectorObject *vecObj in userObj.vectors)
                {
                    if (vecObj.selectable && userObj.enable)
                    {
                        // Note: Take visibility into account too
                        MaplyCoordinate coord;
                        coord.x = geoPt.x()-userObj.vectorOffset.x();
                        coord.y = geoPt.y()-userObj.vectorOffset.y();
                        if ([vecObj pointInAreal:coord])
                        {
                            [foundObjs addObject:vecObj];
                            if (!multi)
                                break;
                        } else {
                            // Check for distance to outline
                            double dist2 = [self dist2Squared:vecObj within:screenDist touch:screenPt placeInfo:pInfo];
                            if (dist2 < screenDist * screenDist)
                            {
                                [foundObjs addObject:vecObj];
                                if (!multi)
                                    break;
                            }
                        }
                    }
                }
                
                if (!multi && [foundObjs count] > 0)
                    break;
            }
        }
    }
    
    return foundObjs;
}

// Distance we'll search around features
static const float ScreenSearchDist = 27.0;

// Do the logic for a selection
// Runs in the layer thread
- (void) userDidTapLayerThread:(WhirlyGlobeTapMessage *)msg
{
    lastTouched = CFAbsoluteTimeGetCurrent();
    if (autoSpinner)
    {
        if (globeView.delegate == autoSpinner)
        {
            autoSpinner = nil;
            globeView.delegate = nil;
        }
    }
    
    // First, we'll look for labels and markers
    SelectionManager *selectManager = (SelectionManager *)scene->getManager(kWKSelectionManager);
    std::vector<SelectionManager::SelectedObject> selectedObjs;
    selectManager->pickObjects(Point2f(msg.touchLoc.x,msg.touchLoc.y),ScreenSearchDist,globeView,selectedObjs);

    NSMutableArray *retSelectArr = [NSMutableArray array];
    if (!selectedObjs.empty())
    {
        // Work through the objects the manager found, creating entries for each
        for (unsigned int ii=0;ii<selectedObjs.size();ii++)
        {
            SelectionManager::SelectedObject &theSelObj = selectedObjs[ii];
            MaplySelectedObject *selObj = [[MaplySelectedObject alloc] init];

            SelectObjectSet::iterator it = selectObjectSet.find(SelectObject(theSelObj.selectID));
            if (it != selectObjectSet.end())
                selObj.selectedObj = it->obj;

            selObj.screenDist = theSelObj.screenDist;
            selObj.screenDistToCenter = theSelObj.screenDistToCenter;
            selObj.zDist = theSelObj.distIn3D;
            
            if (selObj.selectedObj)
                [retSelectArr addObject:selObj];
        }
    }
    
    // Next, try the vectors
    NSArray *vecObjs = [self findVectorsNearScreenPt:Point2f(msg.touchLoc.x,msg.touchLoc.y)geoPt:Point2f(msg.whereGeo.x(),msg.whereGeo.y()) screenDist:ScreenSearchDist multi:true];
//    NSArray *vecObjs = [self findVectorsInPoint:Point2f(msg.whereGeo.x(),msg.whereGeo.y())];
    for (MaplyVectorObject *vecObj in vecObjs)
    {
        MaplySelectedObject *selObj = [[MaplySelectedObject alloc] init];
        selObj.selectedObj = vecObj;
        selObj.screenDist = 0.0;
        // Note: Not quite right
        selObj.zDist = 0.0;
        [retSelectArr addObject:selObj];
    }
    
    // Tell the view controller about it
    dispatch_async(dispatch_get_main_queue(),^
    {
       [_viewController handleSelection:msg didSelect:retSelectArr];
    }
    );
}

// Check for a selection
- (void) userDidTap:(WhirlyGlobeTapMessage *)msg
{
    // Pass it off to the layer thread
    [self performSelector:@selector(userDidTapLayerThread:) onThread:layerThread withObject:msg waitUntilDone:NO];
}

@end
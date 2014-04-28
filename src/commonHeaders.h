/*
*	Commonly includes headers and definitions
*/
#ifndef COMMON_HEADERS
#define COMMON_HEADERS

#include <iostream>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
#include <vector>
#include <string>
#include <math.h>
#include <algorithm>
#include <cuda.h>

//OpenCV is modular
#include <opencv2/opencv.hpp>
#include <opencv2/core/core.hpp>
#include <opencv2/highgui/highgui.hpp>		//IO ops
//#include <opencv2/features2d/features2d.hpp>
//#include <opencv2/nonfree/features2d.hpp>
//#include <opencv2/nonfree/nonfree.hpp>
#include <opencv2/imgproc/imgproc.hpp>
#include <opencv2/calib3d/calib3d.hpp>

using namespace std;
using namespace cv;

#define ESC 27

// handy error macro:
#define GPU_CHECKERROR( err ) (gpuCheckError( err, __FILE__, __LINE__ ))
inline static void gpuCheckError( cudaError_t err,
                          const char *file,
                          int line ) {
    if (err != cudaSuccess) {
        printf( "%s in %s at line %d\n", cudaGetErrorString( err ),
               file, line );
        exit( EXIT_FAILURE );
    }
}

#endif

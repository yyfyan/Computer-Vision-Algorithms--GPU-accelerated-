#include "commonHeaders.h"

#define OCTAVES 5
#define SCALES 3

//Constant buffer for the gaussian kernel
#define D_MAX 50		//10000Bytes < 64KB
__constant__ float d_const_Gaussian[D_MAX*D_MAX];

//Converts the image to gray scale using equal weighting.
Mat toGray(Mat img){
	
	Mat grayImg( img.rows, img.cols,CV_8UC3);
	unsigned char * imgPtr = (unsigned char *)img.data;
	unsigned char * grayPtr = (unsigned char *)grayImg.data;
	
	for(int j = 0; j < img.rows; j++){
		for(int i = 0; i <img.cols*3; i+=3){
		
			int b = imgPtr[img.step*j+i];
			int g = imgPtr[img.step*j+i+1];
			int r = imgPtr[img.step*j+i+2];
			
			int gscale = (b+g+r)/3;
			
			grayPtr[img.step*j+i] = gscale;
			grayPtr[img.step*j+i+1] = gscale;
			grayPtr[img.step*j+i+2] = gscale;
		}
	}
	return grayImg;
	
}

//
// Convert to gray scale. Each thread operates on a pixel.
//

__global__ void toGray_GPU(unsigned char * d_imageArray,int w,int h){
	
	int x = blockDim.x*blockIdx.x + threadIdx.x; 
	int y = blockDim.y*blockIdx.y + threadIdx.y;

	if(x >= w || y >= h)
		return;

	
	//store the blurrred image.
	unsigned int idx = ((y * w) + x)*3;
	
	unsigned int tempR = d_imageArray[idx++];
	unsigned int tempG = d_imageArray[idx++];
	unsigned int tempB = d_imageArray[idx++];
	
	tempR = tempG = tempB = (tempR+tempG+tempB)/3;
	
	d_imageArray[--idx] = tempB;
	d_imageArray[--idx] = tempG;
	d_imageArray[--idx] = tempR;
	
}

//Find candidate keypoints as a local extrema of DOG images across scales
//Compare each pixel to it's neigbouring pixels.

Mat GaussianBlurr(Mat img, float * GaussKernel,int hw){

	Mat blurr_img( img.rows,img.cols,CV_32FC3);
	
	int w = 2*hw+1;
	int bstep = blurr_img.step/4;
	unsigned char * imgPtr = (unsigned char *)img.data;
	float * blurrPtr = (float *)blurr_img.data;
	
	for(int j = 0+hw; j < (img.rows-hw); j++){
		for(int i = 0+hw; i <(img.cols-hw)*3; i+=3){
		
			
			float b =0;
			float g =0;
			float r =0;
			
			for(int y = -hw; y <= hw; y++){
				for(int x = -hw; x <= hw ;x++){
					float k = GaussKernel[ (y+hw)*w + x + hw];
					b += imgPtr[img.step*(j+y)+(i+x)+0]*k;
					g += imgPtr[img.step*(j+y)+(i+x)+1]*k;
					r += imgPtr[img.step*(j+y)+(i+x)+2]*k;
				}
			}
			
			blurrPtr[bstep*j+i+0] = b;
			blurrPtr[bstep*j+i+1] = g;
			blurrPtr[bstep*j+i+2] = r;
			
			
		}
	}
	return blurr_img;
}	

//Plots a green dot around point (x,y)
void plot(Mat img,int x,int y,int b, int g, int r){
	
	int k=1;
	unsigned char * imgPtr = (unsigned char *)img.data;
	
	for(int j = y-k; j < y+k; j++){
		for(int i = x-k; i < x+k; i++ ){
		
			//Bounds check
			if( j < 0 || j >= img.rows || i < 0 || i >= img.cols){
				continue;
			}
	
			imgPtr[img.step*j+i*3+0] = b;
			imgPtr[img.step*j+i*3+1] = g;
			imgPtr[img.step*j+i*3+2] = r;
		}
	}
	
}

__global__ void imageDiff_GPU(float * d_image1, float * d_image2,float * diff_img,int w,int h, float s){
	
	int x = blockDim.x*blockIdx.x + threadIdx.x; 
	int y = blockDim.y*blockIdx.y + threadIdx.y;

	if(x >= w || y >= h)
		return;

	
	//store the blurrred image.
	unsigned int idx = ((y * w) + x)*3;
	
	diff_img[idx+0] = abs((d_image2[idx+0]-d_image1[idx+0])/(1-s));
	diff_img[idx+1] = abs((d_image2[idx+1]-d_image1[idx+1])/(1-s));
	diff_img[idx+2] = abs((d_image2[idx+2]-d_image1[idx+2])/(1-s));
}

//Find the difference in image instensity 
Mat imageDiff(Mat image1, Mat image2, float s){

	//Consider using integers/floats instead of unsigned Uint_8
	Mat imgDiff( image1.rows, image1.cols,CV_32FC3);
	
	float * img1Ptr = (float *)image1.data;
	float * img2Ptr = (float *)image2.data;
	float * resultPtr = (float *)imgDiff.data;
	
	int  step = imgDiff.step/4;
	
	for(int j =0 ; j < image1.rows ; j++){
		for(int i = 0 ; i < step; i += 3){
		
			float diff_b = abs((img2Ptr[step*j+i+0] - img1Ptr[step*j+i+0])/(1-s));
			float diff_g = abs((img2Ptr[step*j+i+1] - img1Ptr[step*j+i+1])/(1-s));
			float diff_r = abs((img2Ptr[step*j+i+2] - img1Ptr[step*j+i+2])/(1-s)); 
			
			resultPtr[step*j+i+0] = diff_b;
			resultPtr[step*j+i+1] = diff_g;
			resultPtr[step*j+i+2] = diff_r;
			
		}
	}
	return imgDiff;
}
//
// Gaussian Image blurr. Uses shared memory for speed up.
//

__global__ void GaussianBlurr_GPU(unsigned char * d_imageArray,float * d_imageArrayResult, int w,int h, int r){
	
	int d = 2*r + 1;
	extern __shared__ float  picBlock[];
	
	int x = blockDim.x*blockIdx.x + threadIdx.x; 
	int y = blockDim.y*blockIdx.y + threadIdx.y;

	if(x >= w || y >= h)
		return;
		
	int idx;
	
	unsigned int idxN, idxS, idxW, idxE;
	float tempR = 0.0;
    float tempG = 0.0;
    float tempB = 0.0;
	float Gaus_val = 0.0;
	int	shDim_x = (blockDim.x + 2*r);
	int	shDim_y = (blockDim.y + 2*r);
	int offset = shDim_x * shDim_y;
	int i, j;
	int iSh, jSh;
	
	//Copy the image into shared memory
	//Blocks that do not require boundry check
	if( (blockIdx.x*blockDim.x >=  r )		&& (blockIdx.y*blockDim.y >=  r) &&
		(((blockIdx.x+1)*blockDim.x +r) < w)	&& (((blockIdx.y+1)*blockDim.y +r) < h)){	
		
		//Collaborative loading into shared memory
		for( i = y-r, iSh = threadIdx.y ; i< (blockDim.y*(blockIdx.y + 1) + r)  ; i+=blockDim.y , iSh+=blockDim.y ){
			for( j = x-r, jSh = threadIdx.x ; j < (blockDim.x*(blockIdx.x + 1) + r)  ; j+=blockDim.x , jSh+=blockDim.x){
				picBlock[(iSh*shDim_x+jSh)] = d_imageArray[(i*w+j)*3];
				picBlock[(iSh*shDim_x+jSh)+offset] = d_imageArray[(i*w+j)*3+1];
				picBlock[(iSh*shDim_x+jSh)+offset*2] = d_imageArray[(i*w+j)*3+2];
			}
		}
	}
	//These blocks may access picture elements that are out of bounds
	else{
		int xLim = blockDim.x*(blockIdx.x + 1) > w ? w : (blockDim.x*(blockIdx.x + 1) + r) ;
		int yLim = blockDim.y*(blockIdx.y + 1) > h ? h : (blockDim.y*(blockIdx.y + 1) + r);
		int xStep = blockDim.x*(blockIdx.x + 1) > w ? w%blockDim.x : blockDim.x ;
		int yStep = blockDim.y*(blockIdx.y + 1) > h ? h%blockDim.y : blockDim.y ;
		
		//Collaborative loading into shared memory
		for( i = y-r, iSh = threadIdx.y ; i< yLim ; iSh+=yStep , i +=yStep ){
			for( j = x-r, jSh = threadIdx.x ; j < xLim ; jSh+=xStep , j +=xStep){
				
				idxN = i<0? 0 : (i>=h ? h-1 : i );
				idxS = j<0? 0 : (j>=w ? w-1 : j );
	
				picBlock[(iSh*shDim_x+jSh)] = d_imageArray[(idxN*w+idxS)*3];
				picBlock[(iSh*shDim_x+jSh)+offset] = d_imageArray[(idxN*w+idxS)*3+1];
				picBlock[(iSh*shDim_x+jSh)+offset*2] = d_imageArray[(idxN*w+idxS)*3+2];			
			}
		}
		
	}
	__syncthreads();		//Make sure every thread has loaded all its portions.
	
	/*
	* All the subblocks are now in shared memory. Now we blurr the image.
	*/

	
	for( i = 0; i <= r; i++){
		//Kernel is symetrix along x and y axis.
		idxN = idxS = ((threadIdx.y+r+i)*shDim_x + (threadIdx.x+r));
		idxW = idxE = ((threadIdx.y+r-i)*shDim_x + (threadIdx.x+r));
		iSh = (i+r)*d+r;
		
		//Loop Unrolling 2 times.
		for( j = 0; j <= r-1 ; j+=2){
				
			Gaus_val = d_const_Gaussian[ iSh ];
			tempR += (picBlock[idxN]+picBlock[idxS] + picBlock[idxE]+picBlock[idxW])*Gaus_val;
			tempG += (picBlock[idxN+offset]+picBlock[idxS+offset]+picBlock[idxE+offset]+picBlock[idxW+offset])*Gaus_val;
			tempB += (picBlock[idxN+offset*2]+picBlock[idxS+offset*2]+picBlock[idxE+offset*2]+picBlock[idxW+offset*2])*Gaus_val;
			
			idxS++;	idxN--;	idxE++;	idxW--; iSh++;
			
			Gaus_val = d_const_Gaussian[ iSh ];
			tempR += (picBlock[idxN]+picBlock[idxS] + picBlock[idxE]+picBlock[idxW])*Gaus_val;
			tempG += (picBlock[idxN+offset]+picBlock[idxS+offset]+picBlock[idxE+offset]+picBlock[idxW+offset])*Gaus_val;
			tempB += (picBlock[idxN+offset*2]+picBlock[idxS+offset*2]+picBlock[idxE+offset*2]+picBlock[idxW+offset*2])*Gaus_val;
			
			idxS++;	idxN--;	idxE++;	idxW--; iSh++;

		}
		//Complete the unrolled portion
		for(  ; j <= r ; j++){
			Gaus_val = d_const_Gaussian[ iSh ];
			tempR += (picBlock[idxN]+picBlock[idxS] + picBlock[idxE]+picBlock[idxW])*Gaus_val;
			tempG += (picBlock[idxN+offset]+picBlock[idxS+offset]+picBlock[idxE+offset]+picBlock[idxW+offset])*Gaus_val;
			tempB += (picBlock[idxN+offset*2]+picBlock[idxS+offset*2]+picBlock[idxE+offset*2]+picBlock[idxW+offset*2])*Gaus_val;
			
			idxS++;	idxN--;	idxE++;	idxW--; iSh++;

		}
	}
	
	//store the blurrred image.
	idx = ((y * w) + x)*3;
	d_imageArrayResult[idx++] = tempB;
	d_imageArrayResult[idx++] = tempG;
	d_imageArrayResult[idx++] = tempR;	
}

//Find the 3d image gradients from a stack of Difference of gaussians. 
Mat imageGradient(Mat* imageStack, Mat plotImg, int octaves, int scales, float threshold , int hwGrad, int hwFeat, vector<KeyPoint> &kp){
	
	float count = 0.0;
	
	//Assumes all the images have the same dimensions.
	int rows = imageStack[0].rows;
	int cols = imageStack[0].cols;
	int step = imageStack[0].step/4;
	
	Mat newImg( rows, cols, CV_32FC3);
	float * newPtr = (float *)newImg.data;
	
	Mat 	dataMat( rows, cols, CV_32FC4 );
	float *	dataMatPtr = (float *)dataMat.data;
	int 	dataMatStep = dataMat.step/4;
	
	cout  << "dataMatStep " << dataMatStep << endl;
	
	//Assumes sigma increases as the scale and octave increases.
	
	//Loops within loops within loops ad infinitum...
	//We cycle over all the images on the stack [octaves x scales] and all the
	//pixels in an image then consider all the neighbouring pixels.
	for(int o = 0; o < octaves ; o++ ){
		for(int s = 1 ; s < scales-1 ; s++ ){
		
			float sigmaScale = pow(2,o)*((float)s/SCALES+1 + 0.5/SCALES); 
			cout << sigmaScale << endl;
			float maxD = 0.0;
			
			int ns = (s+1)%scales;
			int ps = (s+scales-1)%scales;
			int no = o;
			int po = o;
			
			cout << "s " << s << " ns " << ns << " ps " << ps << endl;
			cout << "o " << o << " no " << no << " po " << po << endl;
			
			Mat currImg = imageStack[o*scales + s];
			Mat nextImg = imageStack[no*scales + ns];
			Mat prevImg = imageStack[po*scales + ps];
			
			Mat tempImg( rows, cols, CV_32FC3);
	
			float * tempPtr = (float *)tempImg.data;
	
			float * currPtr = (float *)currImg.data;
			float * nextPtr = (float *)nextImg.data;
			float * prevPtr = (float *)prevImg.data;
			
			float dx_prev = 0.0;
			float dy_prev = 0.0;
			
			//Now we have the image. Consider all the pixels. Remove unstable 
			//Keypoints
			for(int j =1 ; j < rows-1; j++ ){
				for(int i = 3 ; i < step-3; i += 3){
					
					int idx = step*j + i;
					
					//Ignore edge pixels.
					if( j < hwGrad || i < 3*hwGrad || j >= rows -hwGrad || i >= (step -3*hwGrad)){
						tempPtr[idx+0] = 0;
						tempPtr[idx+1] = 0;
						tempPtr[idx+2] = 0;
						continue;
					}
					
					float dx = 0.0;
					float dy = 0.0;
					int patchCount = 0;
					
					//Calculate the gradient by considering neighbouring pixels.
					for(int y = j-hwGrad; y <= j+hwGrad; y++){
						for(int x = i-hwGrad*3; x <= i+hwGrad*3 ;x+=3){
						
							int kernIdx = step*y + x;
							dx += currPtr[kernIdx+3] - currPtr[kernIdx];
							dy += currPtr[kernIdx+step] - currPtr[kernIdx];
							patchCount++;
						}
					}
					//Average the gradients.
					dx /= patchCount;
					dy /= patchCount;
					
					//Gradient and magnitude.
					tempPtr[idx+1] = sqrt(dx*dx + dy*dy);		//Magnitude of gradient
					tempPtr[idx+2] = atan2(dy,dx);				//Orientation of gradient
					float D = currPtr[idx];
					
					//Early termination. These points are unlikely to be keypoints
					//Anyway.
					if(D < threshold ){
						tempPtr[idx+0] = 0.0;			
						continue;
					}
					
					//Key point localization.
					//Eliminate points along the edges.
					float a = dx*dx;
					float b = 2*dx*dy;
					float c = dy*dy;
					
					float elipDet = (b*b+(a-c)*(a-c));

					float l1 = 0.5*(a+c+sqrt(elipDet));
					float l2 = 0.5*(a+c-sqrt(elipDet));
					
					float R = (l1*l2 - 1e-8*(l1+l2)*(l1+l2));
					
					if( R < 0 ){
							//Eliminate points along edges							
							tempPtr[idx+0] = 0;
							continue;
					}else{
						//cout << tempPtr[idx+1] << " ";
					}
					
					//First Derivative.
					float ds_f = nextPtr[idx] - currPtr[idx];	//Forwards
					float ds_b = currPtr[idx] - prevPtr[idx];	//Backwards
					
					//Average them.
					float ds = (ds_f + ds_b)/2;
					float dxVec[3] = {-dx,-dy,-ds};
	
					//Second Derivatives
					float ddx = dx - dx_prev;
					float ddy = dy - dy_prev;
					float dds = ds_f - ds_b;
					
					dx_prev = dx;
					dy_prev = dy;
					
					//Second derivative matrix
				
					float DDMat[3][3] ={{ddx,	dx*dy,	dx*ds},
										{dy*dx,	ddy,	dy*ds},
										{ds*dx,	ds*dy,	dds}};
				
					//Now get its inverse.
					float det =(DDMat[0][0]*DDMat[1][1]*DDMat[2][2] +
								DDMat[0][1]*DDMat[1][2]*DDMat[2][0] +
								DDMat[0][2]*DDMat[1][0]*DDMat[2][1]	) 
								-
							   (DDMat[0][2]*DDMat[1][1]*DDMat[2][0] +
								DDMat[0][1]*DDMat[1][0]*DDMat[2][2] +
								DDMat[0][0]*DDMat[1][2]*DDMat[2][1]	);
				
					
					if(det != 0){
						
						//Adjugate matrix. Matrix of coffactors.
						float CC_00 = DDMat[1][1]*DDMat[2][2] - DDMat[1][2]*DDMat[2][1];
						float CC_01 = DDMat[0][2]*DDMat[2][1] - DDMat[0][1]*DDMat[2][2];
						float CC_02 = DDMat[0][1]*DDMat[1][2] - DDMat[0][2]*DDMat[1][1];
				
						float CC_10 = DDMat[1][2]*DDMat[2][0] - DDMat[1][0]*DDMat[2][2];
						float CC_11 = DDMat[0][0]*DDMat[2][2] - DDMat[0][2]*DDMat[2][0];
						float CC_12 = DDMat[0][2]*DDMat[1][0] - DDMat[0][0]*DDMat[1][2];
				
						float CC_20 = DDMat[1][0]*DDMat[2][1] - DDMat[1][1]*DDMat[2][0];
						float CC_21 = DDMat[0][1]*DDMat[2][0] - DDMat[0][0]*DDMat[2][1];
						float CC_22 = DDMat[0][0]*DDMat[1][1] - DDMat[0][1]*DDMat[1][0];
					
						float CCMat[3][3] ={{CC_00,	CC_01,	CC_02},
											{CC_10,	CC_11,	CC_12},
											{CC_20,	CC_21,	CC_22}};
					
						//Inverse matrix.
						CCMat[0][0] /= det;	CCMat[0][1] /= det;	CCMat[0][2] /= det;
						CCMat[1][0] /= det;	CCMat[1][1] /= det;	CCMat[1][2] /= det;
						CCMat[2][0] /= det;	CCMat[2][1] /= det;	CCMat[2][2] /= det;
				
						//Aproximation factors
						float XBarVec[3]=	{CCMat[0][0]*dxVec[0]+CCMat[0][1]*dxVec[1]+CCMat[0][2]*dxVec[2],
											CCMat[1][0]*dxVec[0]+CCMat[1][1]*dxVec[1]+CCMat[1][2]*dxVec[2],
											CCMat[2][0]*dxVec[0]+CCMat[2][1]*dxVec[1]+CCMat[2][2]*dxVec[2] };
						
						//Remove low contrast extrema.
						float xbarThr = 0.5;
						if( ( abs( XBarVec[0] ) > xbarThr || abs( XBarVec[1] ) > xbarThr || abs( XBarVec[2] ) > xbarThr ) ){
							tempPtr[idx+0] = 0;
							continue;
						}else{
							D += (XBarVec[0]*dxVec[0]+ XBarVec[1]*dxVec[1] + XBarVec[2]*dxVec[2])/2.0;	
						}
					}	
					
					tempPtr[idx+0] = D;

				}
			}
			
			
			//Done getting robust keypoints and calculating image attributes.
			//Now we calculate the feature descriptor vectors. x, y, scale and orienation. 
			
			for(int j =0 ; j < rows; j++ ){
				for(int i = 0  ; i < step; i += 3){
				
					int idx = step*j + i;
					int dataMatidx = dataMatStep*j + i;
					
					//Ignore edge pixels.
					if( j < hwFeat || i < 3*hwFeat || j >= rows -hwFeat || i >= (step -3*hwFeat)){
						dataMatPtr[dataMatidx+0] = 0;
						dataMatPtr[dataMatidx+1] = 0;
						dataMatPtr[dataMatidx+2] = 0;
						dataMatPtr[dataMatidx+3] = 0;
						continue;
					}
					
					bool isKeyPoint = ((tempPtr[idx+0]) >=  threshold);
					
					float phi = M_PI /18.0;		//Radians per bin.
					
					if(isKeyPoint){
					
						dataMatPtr[dataMatidx+0] = i/3;		//Position	x
						dataMatPtr[dataMatidx+1] = j;		//Position	y
						
						float bins[36];
						float 	aveMag = 0.0;
						for(int m = 0; m < 36 ; m++){
							bins[m] = 0;
						}
						
						//Assigning orientation. Use 36 bins and weight sample 
						//by gradient magnitude and gaussian
						for(int y = j-hwFeat; y <= j+hwFeat; y++){
							for(int x = i-hwFeat*3; x <= i+hwFeat*3 ;x+=3){
							
								int 	kernIdx = step*y + x;
								float 	mag = tempPtr[kernIdx+1];
								float	dir = tempPtr[kernIdx+2];
					
								int binIdx = dir/phi+17;
								bins[binIdx] += mag * sigmaScale;
								aveMag += mag; 
								
							}
						}
						
						//Assign the orientation as the highest peak. There could be
						//More peaks which get substantially close to the max value.
						//Also perform polynomial curve fitting for more acurate 
						//Orientation. Will see if all this work is worth doing.
						float highestPeak =0.0;
						for(int m = 0; m < 36 ; m++){
							if(bins[m] > highestPeak){
								highestPeak = bins[m];
							}
							//cout << bins[m] << " ";
						} 
						dataMatPtr[dataMatidx+2] = highestPeak;		//scale
						dataMatPtr[dataMatidx+3] = sigmaScale;
						
						//plot( plotImg , i/3 , j , 0 , 255 , 0 );
						count++;
						
						KeyPoint newKp(i/3,j,sigmaScale,highestPeak,o);
						kp.push_back( newKp );
						
					}
					continue;	
				}	
			}
			
			
		}
	}
	
	cout << "count " << count << endl;
	return newImg;
	
}

//
// Gaussian Image blurr. Uses shared memory for speed up.
//
__global__ void detectKeyPoints_GPU(float * d_imagePrev,float * d_imageCurr,float * d_imageNext, float * d_keyPoints, int w,int h, int r){
	
	extern __shared__ float  picBlock[];
	
	int i = blockDim.x*blockIdx.x + threadIdx.x; 
	int j = blockDim.y*blockIdx.y + threadIdx.y;

	if(i >= w || j >= h)
		return;
	
	int d = 2*r + 1;
	unsigned int idxN, idxS, idxW, idxE;
	float tempR = 0.0;
    float tempG = 0.0;
    float tempB = 0.0;
	float Gaus_val = 0.0;
	int	shDim_x = (blockDim.x + 2*r);
	int offset = (blockDim.x + 2*r)*(blockDim.y + 2*r);
	int x, y;
	int xSh, ySh;
	
	//Copy the image into shared memory
	//Blocks that do not require boundry check
	if( (blockIdx.x*blockDim.x >=  r )		&& (blockIdx.y*blockDim.y >=  r) &&
		(((blockIdx.x+1)*blockDim.x +r) < w)	&& (((blockIdx.y+1)*blockDim.y +r) < h)){	
		
		//Collaborative loading into shared memory
		for( y = j-r, ySh = threadIdx.y ; y< (blockDim.y*(blockIdx.y + 1) + r)  ; y+=blockDim.y , ySh+=blockDim.y ){
			for( x = i-r, xSh = threadIdx.x ; x < (blockDim.x*(blockIdx.x + 1) + r)  ; x+=blockDim.x , xSh+=blockDim.x){
				picBlock[(ySh*shDim_x+xSh)] = d_imageCurr[(y*w+x)*3];
				picBlock[(ySh*shDim_x+xSh)+offset] = d_imageCurr[(y*w+x)*3+1];
				picBlock[(ySh*shDim_x+xSh)+offset*2] = d_imageCurr[(y*w+x)*3+2];
			}
		}
	}
	/*
	//These blocks may access picture elements that are out of bounds
	else{
		int xLim = blockDim.x*(blockIdx.x + 1) > w ? w : (blockDim.x*(blockIdx.x + 1) + r) ;
		int yLim = blockDim.y*(blockIdx.y + 1) > h ? h : (blockDim.y*(blockIdx.y + 1) + r);
		int xStep = blockDim.x*(blockIdx.x + 1) > w ? w%blockDim.x : blockDim.x ;
		int yStep = blockDim.y*(blockIdx.y + 1) > h ? h%blockDim.y : blockDim.y ;
		
		//Collaborative loading into shared memory
		for( y = j-r, ySh = threadIdx.y ; y < yLim ; ySh+=yStep , y +=yStep ){
			for( x = i-r, xSh = threadIdx.x ; x < xLim ; xSh+=xStep , x +=xStep){
				
				idxN = y<0? 0 : (y>=h ? h-1 : y );
				idxS = x<0? 0 : (x>=w ? w-1 : x );
	
				picBlock[(ySh*shDim_x+xSh)] = d_imageCurr[(idxN*w+idxS)*3];
				picBlock[(ySh*shDim_x+xSh)+offset] = d_imageCurr[(idxN*w+idxS)*3+1];
				picBlock[(ySh*shDim_x+xSh)+offset*2] = d_imageCurr[(idxN*w+idxS)*3+2];			
			}
		}
		
	}
	__syncthreads();		//Make sure every thread has loaded all its portions.
	
	int idx = w*j*3+i;
	//Ignore edge pixels.
	if( j < r || i < r || j >= h -r || i >= (w - r)){
		d_keyPoints[idx+0] = 0;
		d_keyPoints[idx+1] = 0;
		d_keyPoints[idx+2] = 0;
		return;
	}
	/*
	float dx = 0.0;
	float dy = 0.0;
	int patchCount = 0;
	
	//Calculate the gradient by considering neighbouring pixels.
	for(int y = j-r; y <= j+r; y++){
		for(int x = i-r*3; x <= i+r*3 ;x+=3){
		
			int kernIdx = shDim_x*y + x;
			dx += picBlock[kernIdx+3] - 		picBlock[kernIdx];
			dy += picBlock[kernIdx+shDim_x] - 	picBlock[kernIdx];
			patchCount++;
		}
	}
	//Average the gradients.
	dx /= patchCount;
	dy /= patchCount;
	
	//Gradient and magnitude.
	d_keyPoints[idx+1] = sqrt(dx*dx + dy*dy);		//Magnitude of gradient
	d_keyPoints[idx+2] = atan2(dy,dx);				//Orientation of gradient
	float D = currPtr[idx];
	
	//Early termination. These points are unlikely to be keypoints
	//Anyway.
	if(D < threshold ){
		d_keyPoints[idx+0] = 0.0;			
		return;
	}
	
	/*
	* All the subblocks are now in shared memory. Now we blurr the image.
	*

	
	//Key point localization.
	//Eliminate points along the edges.
	float a = dx*dx;
	float b = 2*dx*dy;
	float c = dy*dy;
	
	float elipDet = (b*b+(a-c)*(a-c));

	float l1 = 0.5*(a+c+sqrt(elipDet));
	float l2 = 0.5*(a+c-sqrt(elipDet));
	
	float R = (l1*l2 - 1e-8*(l1+l2)*(l1+l2));
	
	if( R < 0 ){
			//Eliminate points along edges							
			d_keyPoints[idx+0] = 0;
			return;
	}
	
	//First Derivative.
	float ds_f =  d_imageNext[idx] -  d_imageCurr[idx];	//Forwards
	float ds_b =  d_imageCurr[idx] -  d_imagePrev[idx];	//Backwards
	
	//Average them.
	float ds = (ds_f + ds_b)/2;
	float dxVec[3] = {-dx,-dy,-ds};

	//Second Derivatives
	float ddx = dx - dx_prev;
	float ddy = dy - dy_prev;
	float dds = ds_f - ds_b;
	
	dx_prev = dx;
	dy_prev = dy;
	
	//Second derivative matrix

	float DDMat[3][3] ={{ddx,	dx*dy,	dx*ds},
						{dy*dx,	ddy,	dy*ds},
						{ds*dx,	ds*dy,	dds}};

	//Now get its inverse.
	float det =(DDMat[0][0]*DDMat[1][1]*DDMat[2][2] +
				DDMat[0][1]*DDMat[1][2]*DDMat[2][0] +
				DDMat[0][2]*DDMat[1][0]*DDMat[2][1]	) 
				-
			   (DDMat[0][2]*DDMat[1][1]*DDMat[2][0] +
				DDMat[0][1]*DDMat[1][0]*DDMat[2][2] +
				DDMat[0][0]*DDMat[1][2]*DDMat[2][1]	);

	
	if(det != 0){
		
		//Adjugate matrix. Matrix of coffactors.
		float CC_00 = DDMat[1][1]*DDMat[2][2] - DDMat[1][2]*DDMat[2][1];
		float CC_01 = DDMat[0][2]*DDMat[2][1] - DDMat[0][1]*DDMat[2][2];
		float CC_02 = DDMat[0][1]*DDMat[1][2] - DDMat[0][2]*DDMat[1][1];

		float CC_10 = DDMat[1][2]*DDMat[2][0] - DDMat[1][0]*DDMat[2][2];
		float CC_11 = DDMat[0][0]*DDMat[2][2] - DDMat[0][2]*DDMat[2][0];
		float CC_12 = DDMat[0][2]*DDMat[1][0] - DDMat[0][0]*DDMat[1][2];

		float CC_20 = DDMat[1][0]*DDMat[2][1] - DDMat[1][1]*DDMat[2][0];
		float CC_21 = DDMat[0][1]*DDMat[2][0] - DDMat[0][0]*DDMat[2][1];
		float CC_22 = DDMat[0][0]*DDMat[1][1] - DDMat[0][1]*DDMat[1][0];
	
		float CCMat[3][3] ={{CC_00,	CC_01,	CC_02},
							{CC_10,	CC_11,	CC_12},
							{CC_20,	CC_21,	CC_22}};
	
		//Inverse matrix.
		CCMat[0][0] /= det;	CCMat[0][1] /= det;	CCMat[0][2] /= det;
		CCMat[1][0] /= det;	CCMat[1][1] /= det;	CCMat[1][2] /= det;
		CCMat[2][0] /= det;	CCMat[2][1] /= det;	CCMat[2][2] /= det;

		//Aproximation factors
		float XBarVec[3]=	{CCMat[0][0]*dxVec[0]+CCMat[0][1]*dxVec[1]+CCMat[0][2]*dxVec[2],
							CCMat[1][0]*dxVec[0]+CCMat[1][1]*dxVec[1]+CCMat[1][2]*dxVec[2],
							CCMat[2][0]*dxVec[0]+CCMat[2][1]*dxVec[1]+CCMat[2][2]*dxVec[2] };
		
		//Remove low contrast extrema.
		float xbarThr = 0.5;
		if( ( abs( XBarVec[0] ) > xbarThr || abs( XBarVec[1] ) > xbarThr || abs( XBarVec[2] ) > xbarThr ) ){
			d_keyPoints[idx+0] = 0;
			return;
		}else{
			D += (XBarVec[0]*dxVec[0]+ XBarVec[1]*dxVec[1] + XBarVec[2]*dxVec[2])/2.0;	
		}
	}	
	
	d_keyPoints[idx+0] = D;
	*/
}

//Find the 3d image gradients from a stack of Difference of gaussians. 
Mat imageGradient_GPU(	float * d_imageStack, Mat plotImg, int octaves, int scales, float threshold , 
						int hwGrad, int hwFeat, vector<KeyPoint> &kp,dim3 numBlocks,dim3 numThreads){
	
	float count = 0.0;
	
	cudaDeviceProp dev_prop_curr;
	cudaGetDeviceProperties( &dev_prop_curr , 0);
	size_t sharedBlockSZ = 3*(numBlocks.x+2*hwGrad) * (numBlocks.y+2*hwGrad) * sizeof(float);	//Picture blocks
	if(sharedBlockSZ > dev_prop_curr.sharedMemPerBlock){
		printf("Shared Memory exceeded allocated size per block: %lu Max %lu\n",sharedBlockSZ, dev_prop_curr.sharedMemPerBlock);
		exit(0);
	}
		
		
	//Assumes all the images have the same dimensions.
	int rows = plotImg.rows;
	int cols = plotImg.cols;
	int step = plotImg.step;
	int chan = plotImg.channels();
	
	Mat newImg( rows, cols, CV_32FC3);
	float * newPtr = (float *)newImg.data;
	
	Mat 	dataMat( rows, cols, CV_32FC4 );
	float *	dataMatPtr = (float *)dataMat.data;
	int 	dataMatStep = dataMat.step;		//<< TODO
			
			
	//Assumes sigma increases as the scale and octave increases.
	
	//Loops within loops within loops ad infinitum...
	//We cycle over all the images on the stack [octaves x scales] and all the
	//pixels in an image then consider all the neighbouring pixels.
	for(int o = 1; o < (octaves-1) ; o++ ){
		for(int s = 0 ; s < scales ; s++ ){
		
			
			//float sigmaScale = pow(2,o)*((float)s/SCALES+1 + 0.5/SCALES); 
			//cout << sigmaScale << endl;
			
			
			int ns = s;
			int ps = s;
			int no = (o+1)%octaves;
			int po = (o+octaves-1)%octaves;
			
			cout << "s " << s << " ns " << ns << " ps " << ps << endl;
			cout << "o " << o << " no " << no << " po " << po << endl << endl;
			
			int prevIdx = (po*scales + ps)*rows*cols*chan;
			int	currIdx = (o*scales + s)*rows*cols*chan;
			int nextIdx = (no*scales + ns)*rows*cols*chan;
			
			float * d_keyPoints;
			GPU_CHECKERROR( cudaMalloc((void **)&d_keyPoints, sizeof(float)*rows*cols*chan) );
	
			detectKeyPoints_GPU<<< numBlocks, numThreads , sharedBlockSZ >>>
				(&d_imageStack[prevIdx],&d_imageStack[currIdx],&d_imageStack[nextIdx],d_keyPoints, cols, rows,hwGrad);
			
			GPU_CHECKERROR( cudaGetLastError() );
			GPU_CHECKERROR( cudaDeviceSynchronize() );
			
		}
	}
	
	cout << "count " << count << endl;
	return newImg;
	
}

	
int main()
{
	

	String img1("panorama_image2.jpg");
	String img2("panorama_image1.jpg");
	
	Mat image1 = imread(img1.c_str());
	Mat image2 = imread(img2.c_str());
	
	if(!image1.data || !image2.data){
		cerr << "Could not open or find the image" << endl;
		exit(0);
	}
	
	cudaDeviceProp dev_prop_curr;
	cudaGetDeviceProperties( &dev_prop_curr , 0);
	
	//Get image dimensions. Assumes all images will have the same dimensions.
	unsigned int w = image1.cols;
	unsigned int h = image1.rows;
	
	cout << w << "x" << h << endl;
	/*
	* Key point Detection.
	*/
	
	//
    // process it on the GPU: 
    //	1) copy it to device memory, 
    //	2) process it with a 2d grid of 2d blocks, with each thread assigned to a pixel. 
    //	3) copy it back.
    // 
    float BLOCK_X = 16.0f;
	float BLOCK_Y = 16.0f;
	
	
	//For High end GPUs. Use more threads.
	if( dev_prop_curr.maxThreadsPerBlock >= 1024 ){ 
		BLOCK_X = 32.0f;	
		BLOCK_Y = 32.0f;
	}

	dim3 numThreads( BLOCK_X, BLOCK_Y,1);
	dim3 numBlocks( ceil(w/BLOCK_X), ceil(h/BLOCK_Y),1);
    unsigned char * d_imageArray1;
    unsigned char * d_imageArray2;
    
    //Allocate space on the GPU memory for gray scale convesion. THis images will serve
    //as source operands in the subsquent kernels.
    GPU_CHECKERROR( cudaMalloc((void **)&d_imageArray1, sizeof(unsigned char)*w*h*3) );
    GPU_CHECKERROR( cudaMalloc((void **)&d_imageArray2, sizeof(unsigned char)*w*h*3) );
			
	GPU_CHECKERROR( cudaMemcpy(	d_imageArray1, 
								image1.data, 
								sizeof(unsigned char)*w*h*3, 
								cudaMemcpyHostToDevice ) );	
	
	GPU_CHECKERROR( cudaMemcpy(	d_imageArray2, 
								image1.data, 
								sizeof(unsigned char)*w*h*3, 
								cudaMemcpyHostToDevice ) );	
													
	//
	// GPU conversion to gray scale.
	//
	printf("Launching gray scale kernel\n");
	toGray_GPU<<< numBlocks, numThreads>>>( d_imageArray1,w,h);
	toGray_GPU<<< numBlocks, numThreads>>>( d_imageArray2,w,h);
	GPU_CHECKERROR( cudaGetLastError() );
    GPU_CHECKERROR( cudaDeviceSynchronize() );	
    
	//Convert the images to gray scale
	//Mat gray_image1 = toGray(image1);
	//Mat gray_image2 = toGray(image2);
	
	GPU_CHECKERROR( cudaMemcpy( image1.data, 
								d_imageArray1, 
								sizeof(unsigned char)*w*h*3, 
								cudaMemcpyDeviceToHost ) );
								
	GPU_CHECKERROR( cudaMemcpy( image2.data, 
								d_imageArray2, 
								sizeof(unsigned char)*w*h*3, 
								cudaMemcpyDeviceToHost ) );
		
						
	namedWindow(img1.c_str(),CV_WINDOW_NORMAL);
	namedWindow(img2.c_str(),CV_WINDOW_NORMAL);
	//resizeWindow(img1.c_str(),800,600);
	//resizeWindow(img2.c_str(),800,600);
	imshow(img1.c_str(),image1);
	imshow(img2.c_str(),image2);
	
	imwrite("grayImage1.jpg",image1);
	imwrite("grayImage2.jpg",image2);
	
	
	waitKey(0);
	
	int octaves = OCTAVES;
	int scales = SCALES;
	//Assumes all the images have the same dimensions.
	int rows = image1.rows;
	int cols = image1.cols;
	int step = image1.step;
	int chan = image1.channels();	
		
	float sf = 1.0f/scales;
	
	//Mat imageStack_1[octaves][scales];
	//Mat imageStack_2[octaves][scales];
	
	float * d_imageStack1;
	float * d_imageStack2;

	//Allocate space on the GPU memory for Gaussian blurr with different Kernel sizes.
    GPU_CHECKERROR( cudaMalloc((void **)&d_imageStack1, sizeof(float)*rows*cols*chan*octaves*scales) );
    GPU_CHECKERROR( cudaMalloc((void **)&d_imageStack2, sizeof(float)*rows*cols*chan*octaves*scales) );
 
 	cout << sizeof(float)*rows*cols*chan*octaves*scales << endl;

    
	for( int o = 0; o < octaves ; o++ ){
	
		int s = 0;
		for(float k = 1.0f; k < 2.0f; k += sf, s++){
	
			//Creates a gaussian kernel (normalized 2d distribution).
			float m = o+1;
			int	hw = 2*m+s;
			int	w = 2*hw+1;
			float sigma = pow(2,o)*k;
			cout << "sigma " << sigma << endl;
			float h_Gaussian[w][w];
			float total = 0.0f;
			
			if( (D_MAX*D_MAX) < w*w ){
				cerr << "Exceded size of constant memory for gaussian blurr kernel." << endl;
				exit(0);
			}
			
			size_t sharedBlockSZ = 3*(BLOCK_X+2*hw) * (BLOCK_Y+2*hw) * sizeof(float);	//Picture blocks
			if(sharedBlockSZ > dev_prop_curr.sharedMemPerBlock){
				printf("Shared Memory exceeded allocated size per block: %lu Max %lu\n",sharedBlockSZ, dev_prop_curr.sharedMemPerBlock);
				return -1;
			}
		
	
			//Gaussian Kernel
			for(int i = -hw; i <= hw ;i++){
				for(int j = -hw; j <= hw ;j++){
		
					float g = exp( -(i*i + j*j)/(2*sigma*sigma) );
			
					h_Gaussian[i+hw][j+hw] = g;
					total += g;
				}
			}
			//Normalize the gaussian Kernel
			for(int i = -hw; i <= hw ;i++){
				for(int j = -hw; j <= hw ;j++){
		
					h_Gaussian[i+hw][j+hw] /= total;
					if(i==0){
						h_Gaussian[i+hw][j+hw]/=2.0f;
					}
					if(j==0){
						h_Gaussian[i+hw][j+hw]/=2.0f;
					}
				}
			}
			
			//Copy the gaussian Kernel to constant memory.
			GPU_CHECKERROR( cudaMemcpyToSymbol( 
    							d_const_Gaussian, 
    							&h_Gaussian[0][0], 
    							sizeof(float)*w*w,
    							0,
    							cudaMemcpyHostToDevice));
    							
			//imageStack_1[o][s] = GaussianBlurr(gray_image1,&gaussKernel[0][0],hw);
			//imageStack_2[o][s] = GaussianBlurr(gray_image2,&gaussKernel[0][0],hw);
			
			int stackIdx =(o*scales + s)*rows*cols*chan;
			GaussianBlurr_GPU<<< numBlocks, numThreads , sharedBlockSZ>>>(d_imageArray1,&d_imageStack1[stackIdx],cols,rows,hw);
			GaussianBlurr_GPU<<< numBlocks, numThreads , sharedBlockSZ>>>(d_imageArray2,&d_imageStack2[stackIdx],cols,rows,hw);
			cout << "image blurr done (" << o << "," << s << ")" << endl;			

			
			//cout << cols << "*" << rows << " | " << step << "_" << chan <<  endl;
	
			Mat newImg1( rows, cols, CV_32FC3);
			float * newPtr1 = (float *)newImg1.data;
			Mat newImg2( rows, cols, CV_32FC3);
			float * newPtr2 = (float *)newImg2.data;
			
			GPU_CHECKERROR( cudaMemcpy( newPtr1, 
										&d_imageStack1[stackIdx], 
										sizeof(float)*rows*cols*chan, 
										cudaMemcpyDeviceToHost ) );
								
			GPU_CHECKERROR( cudaMemcpy( newPtr2, 
										&d_imageStack2[stackIdx], 
										sizeof(float)*rows*cols*chan, 
										cudaMemcpyDeviceToHost ) );
			char buffer1[50];
			char buffer2[50];
			sprintf(buffer1,"blurrImage1_%d_%d.jpg",o,s);
			sprintf(buffer2,"blurrImage2_%d_%d.jpg",o,s);
			imwrite( buffer1,image1);
			imwrite( buffer2,image2);
	
			/*
			namedWindow(img1.c_str(),CV_WINDOW_NORMAL);
			namedWindow(img2.c_str(),CV_WINDOW_NORMAL);
			//resizeWindow(img1.c_str(),800,600);
			//resizeWindow(img2.c_str(),800,600);
			imshow(img1.c_str(),newImg1);
			imshow(img2.c_str(),newImg2);
	
			waitKey(0);
			*/
			
	
		}
	}
	
	GPU_CHECKERROR( cudaGetLastError() );
	GPU_CHECKERROR( cudaDeviceSynchronize() );
    		
	GPU_CHECKERROR( cudaFree(d_imageArray1) );
	GPU_CHECKERROR( cudaFree(d_imageArray2) );
	
	//Scale-space extrema detection.
	//DoG (difference of gaussian images).
	//Mat diff_imgs_1[octaves][scales-1];
	//Mat diff_imgs_2[octaves][scales-1];
	
	float * d_diffImg1;
	float * d_diffImg2;

	//Allocate space on the GPU memory for Gaussian blurr with different Kernel sizes.
    GPU_CHECKERROR( cudaMalloc((void **)&d_diffImg1, sizeof(float)*rows*cols*chan*octaves*(scales-1)) );
    GPU_CHECKERROR( cudaMalloc((void **)&d_diffImg2, sizeof(float)*rows*cols*chan*octaves*(scales-1)) );
    
	
	for(int o=0 ; o < octaves ; o++ ){
	
		int s = 1;
		for( float k = 1.0f + sf; s < scales; k+=sf, s++){
			float diff = k/(k-sf);
			
			unsigned int prevIdx =(o*scales + s-1)*rows*cols*chan;
			unsigned int nextIdx =(o*scales + s)*rows*cols*chan;
			unsigned int currIdx =(o*(scales-1) + s-1)*rows*cols*chan;
			imageDiff_GPU<<< numBlocks, numThreads>>>(&d_imageStack1[prevIdx],&d_imageStack1[nextIdx], &d_diffImg1[currIdx], cols,rows,diff);
			GPU_CHECKERROR( cudaGetLastError() );
			GPU_CHECKERROR( cudaDeviceSynchronize() );
			imageDiff_GPU<<< numBlocks, numThreads>>>(&d_imageStack2[prevIdx],&d_imageStack2[nextIdx], &d_diffImg2[currIdx], cols,rows,diff);
			GPU_CHECKERROR( cudaGetLastError() );
			GPU_CHECKERROR( cudaDeviceSynchronize() );
			//diff_imgs_1[o][s-1]  = imageDiff(imageStack_1[o][s-1],imageStack_1[o][s],diff);
			//diff_imgs_2[o][s-1]  = imageDiff(imageStack_2[o][s-1],imageStack_2[o][s],diff);
			cout << "Diff done (" << o << "," << s -1 << ")" << endl;
	
			Mat newImg1( rows, cols, CV_32FC3);
			float * newPtr1 = (float *)newImg1.data;
			Mat newImg2( rows, cols, CV_32FC3);
			float * newPtr2 = (float *)newImg2.data;
			
			cout << prevIdx << endl;
			GPU_CHECKERROR( cudaMemcpy( newPtr1, 
										&d_diffImg1[currIdx], 
										sizeof(float)*rows*cols*chan, 
										cudaMemcpyDeviceToHost ) );
								
			GPU_CHECKERROR( cudaMemcpy( newPtr2, 
										&d_diffImg2[currIdx], 
										sizeof(float)*rows*cols*chan, 
										cudaMemcpyDeviceToHost ) );
			
			
			namedWindow(img1.c_str(),CV_WINDOW_NORMAL);
			namedWindow(img2.c_str(),CV_WINDOW_NORMAL);
			//resizeWindow(img1.c_str(),800,600);
			//resizeWindow(img2.c_str(),800,600);
			imshow(img1.c_str(),newImg1);
			imshow(img2.c_str(),newImg2);
	
			waitKey(0);	
		}

	}
	
	GPU_CHECKERROR( cudaFree(d_imageStack1));
	GPU_CHECKERROR( cudaFree(d_imageStack2));
	
	
	vector<KeyPoint> keyPoints1;
	vector<KeyPoint> keyPoints2;
	
	
	//float threshold =0.9979;
	float threshold = 0.90;
	int hwGrad = 4;
	int hwFeat = 8;
	//Keypoint localization. Now we have keypoints, we would like to filter out
	//unstable key points and edges.
	//Mat img1Result = imageGradient(&diff_imgs_1[0][0], image1, octaves, scales-1,threshold, hwGrad, hwFeat,keyPoints1);
	//Mat img2Result = imageGradient(&diff_imgs_2[0][0], image2, octaves, scales-1,threshold, hwGrad, hwFeat,keyPoints2);
	
	
	Mat img1Result = imageGradient_GPU(&d_diffImg1[0], image1, octaves, scales-1,threshold, hwGrad, hwFeat,keyPoints1, numBlocks, numThreads);
	Mat img2Result = imageGradient_GPU(&d_diffImg2[0], image2, octaves, scales-1,threshold, hwGrad, hwFeat,keyPoints1, numBlocks, numThreads);

	GPU_CHECKERROR( cudaFree(d_diffImg1));
	GPU_CHECKERROR( cudaFree(d_diffImg2));
	
	namedWindow(img1.c_str(),CV_WINDOW_NORMAL);
	namedWindow(img2.c_str(),CV_WINDOW_NORMAL);
	//resizeWindow(img1.c_str(),800,600);
	//resizeWindow(img2.c_str(),800,600);
	imshow(img1.c_str(),img1Result);
	imshow(img2.c_str(),img1Result);
	

	
	waitKey(0);

	return 0;
	/*
	
	cout << keyPoints1.size() << endl;
	
	//
	// -- Step 1: Detect the keypoints using SURF detector
	int minHessian = 400;
	
	SurfFeatureDetector detector(minHessian);
	
	//detector.detect(gray_image1,keyPoints1);
	//detector.detect(gray_image2,keyPoints2);
	
	Vector<KeyPoint> keypts1;
	Vector<KeyPoint> keypts2;
	
	Mat kp1;
	Mat kp2;
	drawKeypoints(gray_image1,keyPoints1, kp1 , Scalar::all(-1),DrawMatchesFlags::DEFAULT);
	drawKeypoints(gray_image2,keyPoints2, kp2 , Scalar::all(-1),DrawMatchesFlags::DEFAULT);
	
	
	//namedWindow(img1.c_str(),WINDOW_AUTOSIZE);		//Create a window for display
	//namedWindow(img2.c_str(),WINDOW_AUTOSIZE);		//Create a window for display
	//imshow(img1.c_str(),kp1);
	//imshow(img2.c_str(),kp2);
	//waitKey(0);
	
	//Calculate descriptors (feature vectors);
	SurfDescriptorExtractor extractor;
	
	Mat descriptors_object;
	Mat descriptors_scene;
	
	extractor.compute(gray_image1,keyPoints1, descriptors_object);
	extractor.compute(gray_image2,keyPoints2, descriptors_scene);
	
	//FlannBasedMatcher matcher;
	BFMatcher matcher(NORM_L2);
	vector<DMatch> matches;
	matcher.match(descriptors_object, descriptors_scene,matches);
	
	namedWindow("Matches",CV_WINDOW_NORMAL);
	Mat matchImg;
	drawMatches(image1,keyPoints1,image2,keyPoints2,matches,matchImg);
	resizeWindow("Matches",900,400);
	imshow("Matches",matchImg);
	waitKey(0);
	
	double maxDist = 0.0;
	double minDist = 100.0;
	
	//Quick caluculation of max and min distances between keypoints
	for(int i = 0; i < descriptors_object.rows; i++){
		double dist  = matches[i].distance;
		minDist = dist < minDist ? dist : minDist;
		maxDist = dist > maxDist ? dist : maxDist;	
	}
	
	cout << "Maximum Distance: " << maxDist << endl;
	cout << "Minimum Distance: " << minDist << endl;
	
	vector<KeyPoint> kpgood1;
	vector<KeyPoint> kpgood2;	
	//Use only good matches
	double distFilter = 8;
	vector<DMatch> goodMatches;
	for(int i = 0; i < descriptors_object.rows; i++){
		if( matches[i].distance  < minDist * distFilter )
			goodMatches.push_back(matches[i]);
	}
		
	cout << goodMatches.size() << " SZ" << endl;
	
	vector<Point2f> obj;
	vector<Point2f> scn;
	

	
	for(int i = 0; i < goodMatches.size(); i++){
		
		obj.push_back(keyPoints1[goodMatches[i].queryIdx].pt );
		scn.push_back(keyPoints2[goodMatches[i].trainIdx].pt );
		
		//kpgood1.push_back(keyPoints1[goodMatches[i].]);
	}
	
	cout << "After Filtering : " << obj.size() << endl;
	
	
	/*
	namedWindow("Matches",1);
	Mat matchImg;
	drawMatches(image1,keyPoints1,image2,keyPoints2,goodMatches,matchImg);
	imshow("Matches",matchImg);
	waitKey(0);
	
	
	//Find the homography matrix
	Mat H = findHomography(obj,scn,CV_RANSAC);
	
	Mat result;
	warpPerspective(image1,result,H,Size(image1.cols+image2.cols,image1.rows));
	Mat half(result,Rect(0,0,image2.cols,image2.rows));
	
	image2.copyTo(half);
	namedWindow("Result",CV_WINDOW_NORMAL);
	resizeWindow("Result",900,400);
	imshow("Result", result );
	*/
	waitKey(0);
    return 0;
}

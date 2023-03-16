#pragma once
#include <iostream>
#include <filesystem>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <chrono>

#include <opencv2/opencv.hpp>
#include <opencv2/highgui.hpp>

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include "ConvolutionalLayer.h"

using namespace std;
using namespace cv;
using namespace chrono;


/*
* Get all the file names in the specified path.
* Since it's a part of our final project,
* there's no file type checking.
* We assume all the files in the path are images.
* 
* @param path: the path to get the file names
* @return a vector of file names
*/
vector<filesystem::path> getFileNames(const string& path) {
	vector<filesystem::path> files;

	// Check if the path exists
	filesystem::path p(path);
	if (!filesystem::exists(p)) {
		fprintf(stderr, "The specified path does not exist.\n");
		return files;
	}

	// TEST USE
	int count = 0;
	// If the path exist, get all the files in the path
	for (const auto& entry : filesystem::directory_iterator(path)) {
		if (count == 1) break;
		files.push_back(entry.path());
		++count;
	}

	return files;
}


/*
* Load all images found by getFileNames(). There's no file type checking.
* 
* @param files: a vector of file names to be loaded
* @param images: a vector of `Mat` object to store the loaded images
* @return true if successfully loaded at least one image, false otherwise
*/
bool loadImages(const vector<filesystem::path>& files, vector<Mat>& images) {
	if (!files.size()) {
		fprintf(stderr, "No files found in the specified path.\n");
		return false;
	}

	int success = 0;
	int failed = 0;

	for (int i = 0; i < files.size(); i++) {
		Mat image = imread(files[i].string(), IMREAD_GRAYSCALE);
		if (image.empty()) {
			++failed;
			continue;
		}

		++success;
		images.push_back(image);
	}

	printf("Seccussfully loaded %d images, could not load %d images.\n", success, failed);

	return true;
}


/*
* Print devide properties.
*/
void printDeviceProperties() {
	cudaDeviceProp prop;
	cudaGetDeviceProperties(&prop, 0);
	printf("Device Name: %s\n", prop.name);
	printf("Compute Capability: %d.%d\n", prop.major, prop.minor);
	printf("Clock Rate: %d\n", prop.clockRate);
	printf("Total Global Memory: %d\n", prop.totalGlobalMem);
	printf("Total Constant Memory: %d\n", prop.totalConstMem);
	printf("Shared Memory Per Block: %d\n", prop.sharedMemPerBlock);
	printf("Registers Per Block: %d\n", prop.regsPerBlock);
	printf("Warp Size: %d\n", prop.warpSize);
	printf("Max Threads Per Block: %d\n", prop.maxThreadsPerBlock);
	printf("Max Threads Dim: %d %d %d\n", prop.maxThreadsDim[0], prop.maxThreadsDim[1], prop.maxThreadsDim[2]);
	printf("Max Grid Size: %d %d %d\n", prop.maxGridSize[0], prop.maxGridSize[1], prop.maxGridSize[2]);
	printf("Total Constant Memory: %d\n", prop.totalConstMem);
	printf("Major: %d\n", prop.major);
	printf("Minor: %d\n", prop.minor);
	printf("Texture Alignment: %d\n", prop.textureAlignment);
	printf("Device Overlap: %d\n", prop.deviceOverlap);
	printf("Multiprocessor Count: %d\n", prop.multiProcessorCount);
	printf("Kernel Exec Timeout Enabled: %d\n", prop.kernelExecTimeoutEnabled);
}


/*
* Convert OpenCV Mat to 3D int array.
*
*/
bool convertMatToIntArr3D(const vector<Mat> images, int*** intImages3D, const int count, const int row, const int col) {
	if (!images.size()) {
		fprintf(stderr, "Error: images is empty!");
		return false;
	}

	int cnt = 0;
	for (Mat image : images) {
		for (int i = 0; i < row; i++) {
			for (int j = 0; j < col; j++) {
				intImages3D[cnt][i][j] = image.at<uchar>(i, j);
			}
		}
		++cnt;
	}

	return true;
}


/*
* Convert OpenCV Mat to 1D int array.
*
*/
bool convertMatToIntArr1D(const vector<Mat> images, int* intImages1D, const int count, const int row, const int col) {
	if (!images.size()) {
		fprintf(stderr, "Error: images is empty!");
		return false;
	}

	int cnt = 0;
	int image_length = row * col;
	for (Mat image : images) {
		for (int i = 0; i < row; i++) {
			for (int j = 0; j < col; j++) {
				intImages1D[cnt * image_length + i * col + j] = image.at<uchar>(i, j);
			}
		}
	}

	return true;
}


int* flatten3Dto1D(int*** arr3D, int x, int y, int z) {
	int* arr1D = new int[x * y * z];

	for (int i = 0; i < x; i++) {
		for(int j = 0; j < y; j++) {
			for (int k = 0; k < z; k++) {
				arr1D[i * z * y + j * z + k] = arr3D[i][j][k];
			} 
		}
	}
	
	return arr1D;
}


int*** build3Dfrom1D(int* arr1D, int x, int y, int z) {
	int*** arr3D = new int** [x];

	for (int i = 0; i < y; i++) {
		arr3D[i] = new int* [y];
		for (int j = 0; j < y; j++) {
			arr3D[i][j] = new int[z];
		}
	}

	for (int i = 0; i < x; i++) {
		for (int j = 0; j < y; j++) {
			for (int k = 0; k < z; k++) {
				arr3D[i][j][k] = arr1D[i * z * y + j * z + k];
			}
		}
	}

	return arr3D;
}



/*
* Helper function for using CUDA Convolutional Layer.
*/
cudaError_t startCudaCov2Dwith3Darr(
	const int* images, const int* images_output, 
	const int count, const int row, const int col, const int row_output, const int col_output) 
{

	cudaError_t cudaStatus;
	cudaPitchedPtr dev_ptr;
	cudaPitchedPtr dev_ptr_output;

	// Choose which GPU to run on, change this on a multi-GPU system.
	cudaStatus = cudaSetDevice(0);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaSetDevice failed!  Do you have a CUDA-capable GPU installed?");
		goto Error;
	}
	else {
		cout << "cudaSetDevice success!" << endl;
	}

	// Allocate GPU buffers for 3D int array of images
	cudaExtent extent = make_cudaExtent(row * sizeof(int), count, col);
	cudaStatus = cudaMalloc3D(&dev_ptr, extent);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc3D failed!");
		goto Error;
	}
	else {
		cout << "cudaMalloc3D success!" << endl;{}
	}
	// Copy images to device memory
	cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr((void*)images, row * sizeof(int), row, count);
	copyParams.dstPtr = dev_ptr;
	copyParams.extent = extent;
	copyParams.kind = cudaMemcpyHostToDevice;
	cudaStatus = cudaMemcpy3D(&copyParams);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy3D failed!");
		goto Error;
	}
	else
		cout << "cudaMemcpy3D success!" << endl; {} {
	}

	// Allocated GPU buffers for 3D int array of images output
	extent = make_cudaExtent(row_output * sizeof(int), count, col_output);
	cudaStatus = cudaMalloc3D(&dev_ptr_output, extent);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc3D failed!");
		goto Error;
	}
	else {
		cout << "cudaMalloc3D success!" << endl;{}
	}
	// Copy images output to device memory
	copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr((void*)images_output, row_output * sizeof(int), row_output, count);
	copyParams.dstPtr = dev_ptr_output;
	copyParams.extent = extent;
	copyParams.kind = cudaMemcpyHostToDevice;
	cudaStatus = cudaMemcpy3D(&copyParams);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy3D failed!");
		goto Error;
	}
	else {
		cout << "cudaMemcpy3D success!" << endl; {}
	}
	

	// 
	int filter[9] = { 0, 1, 0, 0, 1, 0, 0, 1, 0 };
	dim3 gridDim(1, 1, 1);
	dim3 blockDim(1, 1, 1);
	auto start_conv = high_resolution_clock::now();
	conv2D_cuda3D <<<gridDim, blockDim>>> (dev_ptr, dev_ptr_output, filter, count, row, col, row_output, col_output);

	cudaStatus = cudaGetLastError();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "conv2D_cuda3D launch failed: %s\n", cudaGetErrorString(cudaStatus));
		goto Error;
	}

	cudaStatus = cudaDeviceSynchronize();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaDeviceSynchronize failed!");
		goto Error;
	}

	auto end_conv = high_resolution_clock::now();
	cout << "conv2D_cuda3D success!" << endl;
	auto duration_conv = duration_cast<milliseconds>(end_conv - start_conv).count();
	printf("Convolutional Layer took %d milliseconds to run.\n", duration_conv);

	// Copy output from device memory to host memory
	copyParams = { 0 };
	copyParams.srcPtr = dev_ptr_output;
	copyParams.dstPtr = make_cudaPitchedPtr((void*)images_output, row_output * sizeof(int), row_output, count);
	copyParams.extent = extent;
	copyParams.kind = cudaMemcpyDeviceToHost;
	cudaStatus = cudaMemcpy3D(&copyParams);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy3D failed: %s", cudaGetErrorString(cudaStatus));
		goto Error;
	}
	else {
		cout << "cudaMemcpy3D success!" << endl; {}
	}


Error:
	cudaFree(dev_ptr.ptr);
	cudaFree(dev_ptr_output.ptr);

	return cudaStatus;
}





cudaError_t startCudaCov2Dwith1Darr(const int* images, const int* images_output, int count, int row, int col) {
	int size = count * row * col;
	cudaError_t cudaStatus;
	int* dev_images;
	int* dev_images_output;

	cudaStatus = cudaMalloc((void**)&dev_images, size * sizeof(int));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc failed!");
		goto Error;
	}
	else {
		cout << "cudaMalloc success!" << endl;
	}
	cudaStatus = cudaMalloc((void**)&dev_images_output, size * sizeof(int));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc failed!");
		goto Error;
	}
	else {
		cout << "cudaMalloc success!" << endl;
	}

	cudaStatus = cudaMemcpy(dev_images, images, size * sizeof(int), cudaMemcpyHostToDevice);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!");
		goto Error;
	}
	else {
		cout << "cudaMemcpy success!" << endl;
	}


Error:
	cudaFree(dev_images);
	cudaFree(dev_images_output);

	return cudaStatus;
}
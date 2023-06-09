﻿/*
* Pooling layer GPU implementation
* Author: Yuan Ma
* Date: 3/14/2023
* For: CSS 535: High Performance Computing, Final Project
*/

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <stdio.h>

#include <iostream>
#include <Windows.h>
#include <direct.h>
#include <filesystem>
#include <string>
#include <sys/stat.h>
#include <vector>
#include <chrono>
#include<cstdio>

#include <opencv2/opencv.hpp>
#include <opencv2/highgui.hpp>

using namespace std;
using namespace cv;
using namespace chrono;

#define BASE_PATH ".\\data\\"
#define CATS_PATH ".\\data\\cats\\"
#define CATS_PATH_OUTPUT ".\\data\\cats_output\\"
#define CATS_PATH_BIG ".\\data\\cats_convolved\\cats_output\\"
#define CATS_PATH_FINAL ".\\data\\cats_final\\"
#define DOGS_PATH ".\\data\\dogs\\"
#define DOGS_PATH_OUTPUT ".\\data\\dogs_output\\"
#define POOLING_SIZE 3

void getCurrDir();

vector<filesystem::path> getFileNames(const string& path);

cudaError_t poolingWithCuda(const int* image_array, int* new_image_array, float& time_memcopy, float& time_kernel_run, int count, int row, int col);

int* flatten3Dto1D(int*** arr3D, int x, int y, int z);

bool convertMatToIntArr(const vector<Mat> images, int*** intImages, const int count, const int row, const int col);

bool loadImages(const vector<filesystem::path>& files, vector<Mat>& images);

bool convertIntArr3DToMat(int*** intImages3D, vector<Mat>& images, const int count, const int row, const int col);

int*** build3Dfrom1D(int* arr1D, int x, int y, int z);

// Naive Pooling
__global__ void poolingKernel(cudaPitchedPtr image, cudaPitchedPtr new_image, int count, int row, int col)
{
    // Compute the image index [k] of this thread
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    // Avoid overflow
    if (index < count) {
        // Get the start pointer of this image
        char* imagePtrSlice = (char*)image.ptr + index * image.pitch * col;

        // Get the start pointer of this new image
        char* newimagePtrSlice = (char*)new_image.ptr + index * new_image.pitch * col / POOLING_SIZE;

        // Loop for each pixel of the new image
        for (int i = 0; i < row / POOLING_SIZE; i++) {
            // Get the start pointer of this row of new image
            int* newrowData = (int*)(newimagePtrSlice + i * new_image.pitch);
            for (int j = 0; j < col / POOLING_SIZE; j++) {
                // Find the left upper point in the original image
                int corner_i = i * POOLING_SIZE;
                int corner_j = j * POOLING_SIZE;
            
                // Initialize the maximum
                int maximum = newrowData[j];

                // Loop and find the maximum
                for (int pool_i = corner_i; pool_i < corner_i + POOLING_SIZE; pool_i++) {
                    // Get the start pointer of this row of image
                    int* rowData = (int*)(imagePtrSlice + pool_i * image.pitch);

                    for (int pool_j = corner_j; pool_j < corner_j + POOLING_SIZE; pool_j++) {
                        // The value of the pixel of original image
                        int pixel = rowData[pool_j];

                        // Find maximum
                        maximum = pixel > maximum ? pixel : maximum;
                    }
                }

                // Assign pooling result to the new image
                newrowData[j] = maximum;
            }
        }
    }
}

// Optimized Pooling with array unrolling
__global__ void optimized_poolingKernel(cudaPitchedPtr image, cudaPitchedPtr new_image, int count, int row, int col)
{
    // Compute the image index [k] of this thread
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    // Avoid overflow
    if (index < count) {
        // Get the start pointer of this image
        char* imagePtrSlice = (char*)image.ptr + index * image.pitch * col;

        // Get the start pointer of this new image
        char* newimagePtrSlice = (char*)new_image.ptr + index * new_image.pitch * col / POOLING_SIZE;

        // Loop for each pixel of the new image
        for (int i = 0; i < row / POOLING_SIZE; i++) {
            // Get the start pointer of this row of new image
            int* newrowData = (int*)(newimagePtrSlice + i * new_image.pitch);
            for (int j = 0; j < col / POOLING_SIZE; j++) {
                // Find the left upper point in the original image
                int corner_i = i * POOLING_SIZE;
                int corner_j = j * POOLING_SIZE;

                // Initialize the maximum
                int maximum = newrowData[j];

                // Find the maximum, used loop unrolling, ASSUMED POOLING_SIZE = 3!!!
                int i1 = corner_i + 1;
                int i2 = corner_i + 2;
                int j1 = corner_j + 1;
                int j2 = corner_j + 2;

                int* rowData0 = (int*)(imagePtrSlice + corner_i * image.pitch);
                int* rowData1 = (int*)(imagePtrSlice + i1 * image.pitch);
                int* rowData2 = (int*)(imagePtrSlice + i2 * image.pitch);

                int pixel0 = rowData0[corner_j];
                maximum = pixel0 > maximum ? pixel0 : maximum;

                int pixel1 = rowData0[j1];
                maximum = pixel1 > maximum ? pixel1 : maximum;

                int pixel2 = rowData0[j2];
                maximum = pixel2 > maximum ? pixel2 : maximum;

                int pixel3 = rowData1[corner_j];
                maximum = pixel3 > maximum ? pixel3 : maximum;

                int pixel4 = rowData1[j1];
                maximum = pixel4 > maximum ? pixel4 : maximum;

                int pixel5 = rowData1[j2];
                maximum = pixel5 > maximum ? pixel5 : maximum;

                int pixel6= rowData2[corner_j];
                maximum = pixel6 > maximum ? pixel6 : maximum;

                int pixel7 = rowData2[j1];
                maximum = pixel7 > maximum ? pixel7 : maximum;

                int pixel8 = rowData2[j2];
                maximum = pixel8 > maximum ? pixel8 : maximum;
                
                // Assign pooling result to the new image
                newrowData[j] = maximum;
            }
        }
    }
}

int main()
{
    // Get all images
    vector<filesystem::path> cats_files = getFileNames(CATS_PATH);
    vector<Mat> cats_images;
    bool load_image_status = loadImages(cats_files, cats_images);
    if (!load_image_status) {
        fprintf(stderr, "Could not load images. Program aborted.\n");
        exit(EXIT_FAILURE);
    }

    // Transfer images to a 3d array
    const int col = cats_images[0].cols;
    const int row = cats_images[0].rows;
    const int count = cats_images.size();

    int*** image_array = new int** [count];
    int*** new_image_array = new int** [count];

    for (int cnt = 0; cnt < count; cnt++) {
        image_array[cnt] = new int* [row];
        for (int i = 0; i < row; i++) {
            image_array[cnt][i] = new int[col];
            for (int j = 0; j < col; j++) {
                image_array[cnt][i][j] = 0;
            }
        }
    }

    for (int cnt = 0; cnt < count; cnt++) {
        new_image_array[cnt] = new int* [row / POOLING_SIZE];
        for (int i = 0; i < row / POOLING_SIZE; i++) {
            new_image_array[cnt][i] = new int[col / POOLING_SIZE];
            for (int j = 0; j < col / POOLING_SIZE; j++) {
                new_image_array[cnt][i][j] = 0;
            }
        }
    }

    if (!convertMatToIntArr(cats_images, image_array, count, row, col)) {
        fprintf(stderr, "Could not convert Mat to int array. Program aborted.\n");
        exit(EXIT_FAILURE);
    }

    int* intImages1D = flatten3Dto1D(image_array, count, row, col);
    int* intImages_output1D = flatten3Dto1D(new_image_array, count, row / POOLING_SIZE, col / POOLING_SIZE);

    // Record time
    float pooling_time_total_memcopy = 0.0, pooling_time_total_kernel = 0.0;

    // Finish pooling layer calculation in GPU
    cudaError_t cudaStatus = poolingWithCuda(intImages1D, intImages_output1D, pooling_time_total_memcopy, pooling_time_total_kernel, count, row, col);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "poolingWithCuda failed!");
        return 1;
    }

    // cudaDeviceReset must be called before exiting in order for profiling and
    // tracing tools such as Nsight and Visual Profiler to show complete traces.
    cudaStatus = cudaDeviceReset();
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaDeviceReset failed!");
        return 1;
    }

    /*
    // TEST USE: Show the pictures
    new_image_array = build3Dfrom1D(intImages_output1D, count, row / POOLING_SIZE, col / POOLING_SIZE);

    vector<Mat> images_output;
    convertIntArr3DToMat(new_image_array, images_output, count, row / POOLING_SIZE, col / POOLING_SIZE);

    // Print the image
    int cnt = 0;
    for (auto image : images_output) {
        if (cnt++ == 9) break;
        namedWindow("Image", WINDOW_NORMAL);
        resizeWindow("Image", 600, 600);
        imshow("Image", image);
        waitKey(0);
    }
    */
    

    // Print time stats
    printf("Pooling total time: %f, memcopy: %f, kernel: %f.\n",
        pooling_time_total_memcopy + pooling_time_total_kernel, pooling_time_total_memcopy, pooling_time_total_kernel
    );

    // Cleanup
    for (int k = 0; k < count; k++) {
        for (int i = 0; i < row; i++) {
            delete[] image_array[k][i];
        }
        delete[] image_array[k];

        for (int i = 0; i < row / POOLING_SIZE; i++) {
            delete[] new_image_array[k][i];
        }
        delete new_image_array[k];
    }
    delete[] image_array;
    delete[] new_image_array;

    delete[] intImages1D;
    delete[] intImages_output1D;
    
    return 0;
}


// Helper function for using CUDA to computer pooling layer in parallel
cudaError_t poolingWithCuda(const int* image_array, int* new_image_array, float& time_memcopy, float& time_kernel_run, int count, int row, int col)
{   
    cudaError_t cudaStatus;
    cudaPitchedPtr image_arrptr;
    cudaPitchedPtr new_image_arrptr;

    // For time measurement
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    float time_memcopy_images;
    float time_memcopy_result_in;
    float time_memcopy_result_out;
    float time_kernel;

    // Choose which GPU to run on, change this on a multi-GPU system.
    cudaStatus = cudaSetDevice(0);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaSetDevice failed!  Do you have a CUDA-capable GPU installed?");
        goto Error;
    }

    // Allocate 3D GPU buffer for image array & output array
    cudaExtent extent = make_cudaExtent(row * sizeof(int), count, col);
    cudaStatus = cudaMalloc3D(&image_arrptr, extent);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMalloc3D failed!");
        goto Error;
    }

    extent = make_cudaExtent(row / POOLING_SIZE * sizeof(int), count, col / POOLING_SIZE);
    cudaStatus = cudaMalloc3D(&new_image_arrptr, extent);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMalloc3D failed!");
        goto Error;
    }

    // Copy arrays from host memory to GPU buffers.
    cudaMemcpy3DParms cpy = { 0 };
    cpy.srcPtr = make_cudaPitchedPtr((void*)image_array, row * sizeof(int), row, count);
    cpy.dstPtr = image_arrptr;
    cpy.extent = make_cudaExtent(row * sizeof(int), count, col);
    cpy.kind = cudaMemcpyHostToDevice;
    cudaEventRecord(start);
    cudaStatus = cudaMemcpy3D(&cpy);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time_memcopy_images, start, stop);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMemcpy3D failed!");
        goto Error;
    }

    cudaMemcpy3DParms cpy2 = { 0 };
    cpy2.srcPtr = make_cudaPitchedPtr((void*)new_image_array, row / POOLING_SIZE * sizeof(int), row / POOLING_SIZE, count);
    cpy2.dstPtr = new_image_arrptr;
    cpy2.extent = make_cudaExtent(row / POOLING_SIZE * sizeof(int), count, col / POOLING_SIZE);
    cpy2.kind = cudaMemcpyHostToDevice;
    cudaEventRecord(start);
    cudaStatus = cudaMemcpy3D(&cpy2);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time_memcopy_result_in, start, stop);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMemcpy3D failed!");
        goto Error;
    }

    // Kernel parameters
    int threads_per_block = 1024;
    int num_blocks = count / threads_per_block + 1;

    // Launch the kernel
    cudaEventRecord(start);
    //poolingKernel<<<num_blocks, threads_per_block >>>(image_arrptr, new_image_arrptr, count, row, col);
    optimized_poolingKernel << <num_blocks, threads_per_block >> > (image_arrptr, new_image_arrptr, count, row, col);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time_kernel, start, stop);

    // Check for any errors launching the kernel
    cudaStatus = cudaGetLastError();
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "poolingKernel launch failed: %s\n", cudaGetErrorString(cudaStatus));
        goto Error;
    }

    // cudaDeviceSynchronize waits for the kernel to finish, and returns
    // any errors encountered during the launch.
    cudaStatus = cudaDeviceSynchronize();
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching poolingKernel!\n", cudaStatus);
        goto Error;
    }

    // Copy output image array from GPU buffer to host memory.
    cudaMemcpy3DParms cpy3 = { 0 };
    cpy3.srcPtr = new_image_arrptr;
    cpy3.dstPtr = make_cudaPitchedPtr((void*)new_image_array, row / POOLING_SIZE * sizeof(int), row / POOLING_SIZE, count);
    cpy3.extent = make_cudaExtent(row / POOLING_SIZE * sizeof(int), count, col / POOLING_SIZE);
    cpy3.kind = cudaMemcpyDeviceToHost;
    cudaEventRecord(start);
    cudaStatus = cudaMemcpy3D(&cpy3);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time_memcopy_result_out, start, stop);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMemcpy failed!");
        goto Error;
    }

    // Calculate time
    time_memcopy = time_memcopy_images + time_memcopy_result_in + time_memcopy_result_out;
    time_kernel_run = time_kernel;

Error:
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(image_arrptr.ptr);
    cudaFree(new_image_arrptr.ptr);

    return cudaStatus;
}

void getCurrDir() {
    char cwd[1024];
    if (_getcwd(cwd, sizeof(cwd)) != nullptr) {
        std::cout << "Current working directory: " << cwd << std::endl;
    }
    else {
        std::cerr << "Failed to get current working directory." << std::endl;
    }
}


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
        //if (count == 1) break;
        files.push_back(entry.path());
        ++count;
    }

    return files;
}

/*
* Convert OpenCV Mat to int array.
*
*/
bool convertMatToIntArr(const vector<Mat> images, int*** intImages, const int count, const int row, const int col) {
    if (!images.size()) {
        fprintf(stderr, "Error: images is empty!");
        return false;
    }

    int cnt = 0;
    for (Mat image : images) {
        for (int i = 0; i < row; i++) {
            for (int j = 0; j < col; j++) {
                intImages[cnt][i][j] = image.at<uchar>(i, j);
            }
        }
        ++cnt;
    }

    return true;
}


int* flatten3Dto1D(int*** arr3D, int x, int y, int z) {
    int* arr1D = new int[x * y * z];

    for (int i = 0; i < x; i++) {
        for (int j = 0; j < y; j++) {
            for (int k = 0; k < z; k++) {
                arr1D[i * z * y + j * z + k] = arr3D[i][j][k];
            }
        }
    }

    return arr1D;
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


int*** build3Dfrom1D(int* arr1D, int x, int y, int z) {
    int*** arr3D = new int** [x];

    for (int i = 0; i < x; i++) {
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

    /*for (int i = 0; i < x; i++) {
        for (int j = 0; j < y; j++) {
            for (int k = 0; k < z; k++) {
                cout << arr3D[i][j][k] << " ";
            }
            cout << endl;
        }
        cout << endl;
    }
    cout << endl;*/

    return arr3D;
}

/*
* Convert 3D int array to OpenCV Mat.
*/
bool convertIntArr3DToMat(int*** intImages3D, vector<Mat>& images, const int count, const int row, const int col) {
    int cnt = 0;
    for (int k = 0; k < count; ++k) {
        Mat image(row, col, CV_8UC1);
        for (int i = 0; i < row; i++) {
            for (int j = 0; j < col; j++) {
                image.at<uchar>(i, j) = intImages3D[cnt][i][j];
            }
        }
        images.push_back(image);
        ++cnt;
    }

    return true;
}

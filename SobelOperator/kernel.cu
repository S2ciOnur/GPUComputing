/*************************************************************************************************
 * File: sobelFilter.cu
 * Date: 09/27/2017
 *
 * Compiling: Requires a Nvidia CUDA capable graphics card and the Nvidia GPU Computing Toolkit.
 *            Linux: nvcc -Wno-deprecated-gpu-targets -O3 -o edge sobelFilter.cu lodepng.cpp -Xcompiler -fopenmp
 *
 * Usage:   Linux: >> edge [filename.png]
 *
 * Description: This file is meant to handle all the sobel filter functions as well as the main
 *      function. Each sobel filter function runs in a different way than the others, one is a basic
 *      sobel filter running through just the cpu on a single thread, another runs through openmp
 *      to parallelize the single thread cpu function, and the last one runs through a NVIDIA gpu
 *      to parallelize the function onto the many cores available on the gpu.
 *************************************************************************************************/

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <thread>
#include <chrono>
#include <vector>
#include <time.h>
#include <iostream>
#include <math.h>
#include <omp.h>
#include <filesystem>
#include "imageLoader.h"

#define GRIDVAL 20.0 

//=============================================================================================================================
//                                                  Function Definitions
//=============================================================================================================================
void printCudaDeviceInformation(int maxAvaialbeCores);
void executeSobelOperator(char* image, int maxAvaialbeCores);

//cpu sobel functions (sorted from slowest to fastest)
void separateStepSobelCpuWithIndexing(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores);
void separateStepSobelCpuWithInlineIndexing(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores);
void separateStepSobelCpuWithoutIndexing(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores);
void separateStepSobelCpuOptimizedCalculation(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores);
void combinedStepsSobelCpu(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores);
void combinedStepsSobelCpuOptimized(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores);

void combined_step_sobel_cpu(const byte* orig, byte* cpu, const unsigned int width, const unsigned int height);
void sobel_omp(const byte* orig, byte* cpu, const unsigned int width, const unsigned int height);

int imageWidth = 0;

/**
* Index function to access a 1d array like a 2d array
*/
int getIndex(int x, int y) {
    return imageWidth * y + x;
};

//same as inline function
inline int getIndexInline(int x, int y) {
    return imageWidth * y + x;
};

/************************************************************************************************
 * void sobel_gpu(const byte*, byte*, uint, uint);
 * - This function runs on the GPU, it works on a 2D grid giving the current x, y pair being worked
 * - on, the const byte* is the original image being processed and the second byte* is the image
 * - being created using the sobel filter. This function runs through a given x, y pair and uses
 * - a sobel filter to find whether or not the current pixel is an edge, the more of an edge it is
 * - the higher the value returned will be
 *
 * Inputs: const byte* orig : the original image being evaluated
 *                byte* cpu : the image being created using the sobel filter
 *               uint width : the width of the image
 *              uint height : the height of the image
 *
 ***********************************************************************************************/
__global__ void sobel_gpu(const byte* orig, byte* cpu, const unsigned int width, const unsigned int height) {
    int x = threadIdx.x + blockIdx.x * blockDim.x;
    int y = threadIdx.y + blockIdx.y * blockDim.y;
    float dx, dy;
    if (x > 0 && y > 0 && x < width - 1 && y < height - 1) {
        dx = (-1 * orig[(y - 1) * width + (x - 1)]) + (-2 * orig[y * width + (x - 1)]) + (-1 * orig[(y + 1) * width + (x - 1)]) +
            (orig[(y - 1) * width + (x + 1)]) + (2 * orig[y * width + (x + 1)]) + (orig[(y + 1) * width + (x + 1)]);
        dy = (orig[(y - 1) * width + (x - 1)]) + (2 * orig[(y - 1) * width + x]) + (orig[(y - 1) * width + (x + 1)]) +
            (-1 * orig[(y + 1) * width + (x - 1)]) + (-2 * orig[(y + 1) * width + x]) + (-1 * orig[(y + 1) * width + (x + 1)]);
        cpu[y * width + x] = sqrt((dx * dx) + (dy * dy));
    }
}

/************************************************************************************************
 * int main(int, char*[])
 * - This function is our program's entry point. The function passes in the command line arguments
 * - and if there are exactly 2 command line arguments, the program will continue, otherwise it
 * - will exit with error code 1. If the program continues, it will read in the file given by
 * - command line argument #2 and store as an array of bytes, after some header information is
 * - outputted, the sobel filter will run in 3 different functions on the original image and
 * - 3 new images will be created, each containing a sobel filter created using just the CPU,
 * - OMP, and the GPU, then the image will be written out to a file with an appropriate indicator
 * - appended to the end of the filename.
 *
 * Inputs:    int argc : the number of command line arguments
 *         char*argv[] : an array containing the command line arguments
 * Outputs:   returns 0: code ran successful, no issues came up
 *            returns 1: invalid number of command line arguments
 *            returns 2: unable to process input image
 *            returns 3: unable to write output image
 *
 ***********************************************************************************************/
int main(int argc, char* argv[]) {
    //wraps the input arguments in a vector
    std::vector<char*> arguments(argv, argv + argc);

    //gets the max available number of cpu cores
    int maxAvaialbeCores = std::thread::hardware_concurrency();
    //Check if the user started the program with a valid number of arguments
    if (arguments.size() < 2) {
        printf("%s: Invalid number of command line arguments. Exiting program\n", argv[0]);
        printf("Usage: %s [image.png]", argv[0]);
        return 1;
    }

    //the first argument is no longer needed, therefore it gets removed
    arguments.erase(arguments.begin());

    //print device properties
    printCudaDeviceInformation(maxAvaialbeCores);

    //switch (devProp.major)
    //{
    //case 2: // Fermi
    //    if (devProp.minor == 1) cores *= 48;
    //    else cores *= 32; break;
    //case 3: // Kepler
    //    cores *= 192; break;
    //case 5: // Maxwell
    //    cores *= 128; break;
    //case 6: // Pascal
    //    if (devProp.minor == 1) cores *= 128;
    //    else if (devProp.minor == 0) cores *= 64;
    //    break;
    //}

    //load image (currently only png supported)
    for (char* image : arguments) {
        printf("\n\n########################################################\n");
        printf("#  Starting image processing: %-25.25s#\n", image);
        printf("########################################################\n");
        executeSobelOperator(image, maxAvaialbeCores);
    }

    /** Load our img and allocate space for our modified images **/
    imgData origImg = loadImage(argv[1]);
    imageWidth = origImg.width;
    imgData cpuImg(new byte[origImg.width * origImg.height], origImg.width, origImg.height);
    imgData ompImg(new byte[origImg.width * origImg.height], origImg.width, origImg.height);
    imgData gpuImg(new byte[origImg.width * origImg.height], origImg.width, origImg.height);

    /** make sure all our newly allocated data is set to 0 **/
    memset(cpuImg.pixels, 0, (origImg.width * origImg.height));
    memset(ompImg.pixels, 0, (origImg.width * origImg.height));

    /** We first run the sobel filter on just the CPU using only 1 thread **/
    auto c = std::chrono::system_clock::now();
    combined_step_sobel_cpu(origImg.pixels, cpuImg.pixels, origImg.width, origImg.height);
    std::chrono::duration<double> time_cpu = std::chrono::system_clock::now() - c;

    /** Next, we use OpenMP to parallelize it **/
    c = std::chrono::system_clock::now();
    sobel_omp(origImg.pixels, ompImg.pixels, origImg.width, origImg.height);
    std::chrono::duration<double> time_omp = std::chrono::system_clock::now() - c;

    /** Finally, we use the GPU to parallelize it further **/
    /** Allocate space in the GPU for our original img, new img, and dimensions **/
    byte* gpu_orig, * gpu_sobel;
    cudaMalloc((void**)&gpu_orig, (origImg.width * origImg.height));
    cudaMalloc((void**)&gpu_sobel, (origImg.width * origImg.height));
    /** Transfer over the memory from host to device and memset the sobel array to 0s **/
    cudaMemcpy(gpu_orig, origImg.pixels, (origImg.width * origImg.height), cudaMemcpyHostToDevice);
    cudaMemset(gpu_sobel, 0, (origImg.width * origImg.height));

    /** set up the dim3's for the gpu to use as arguments (threads per block & num of blocks)**/
    dim3 threadsPerBlock(GRIDVAL, GRIDVAL, 1);
    dim3 numBlocks(ceil(origImg.width / GRIDVAL), ceil(origImg.height / GRIDVAL), 1);

    /** Run the sobel filter using the CPU **/
    c = std::chrono::system_clock::now();
    sobel_gpu <<<numBlocks, threadsPerBlock>>> (gpu_orig, gpu_sobel, origImg.width, origImg.height);
    cudaError_t cudaerror = cudaDeviceSynchronize(); // waits for completion, returns error code
    if (cudaerror != cudaSuccess) fprintf(stderr, "Cuda failed to synchronize: %s\n", cudaGetErrorName(cudaerror)); // if error, output error
    std::chrono::duration<double> time_gpu = std::chrono::system_clock::now() - c;
    /** Copy data back to CPU from GPU **/
    cudaMemcpy(gpuImg.pixels, gpu_sobel, (origImg.width * origImg.height), cudaMemcpyDeviceToHost);

    /** Output runtimes of each method of sobel filtering **/
    printf("\nProcessing %s: %d rows x %d columns\n", argv[1], origImg.height, origImg.width);
    printf("CPU execution time    = %*.1f msec\n", 5, 1000 * time_cpu.count());
    printf("OpenMP execution time = %*.1f msec\n", 5, 1000 * time_omp.count());
    printf("CUDA execution time   = %*.1f msec\n", 5, 1000 * time_gpu.count());
    printf("\nCPU->OMP speedup:%*.1f X", 12, (1000 * time_cpu.count()) / (1000 * time_omp.count()));
    printf("\nOMP->GPU speedup:%*.1f X", 12, (1000 * time_omp.count()) / (1000 * time_gpu.count()));
    printf("\nCPU->GPU speedup:%*.1f X", 12, (1000 * time_cpu.count()) / (1000 * time_gpu.count()));
    printf("\n");

    /** Output the images of each sobel filter with an appropriate string appended to the original image name **/
    writeImage(argv[1], "gpu", gpuImg);
    writeImage(argv[1], "cpu", cpuImg);
    writeImage(argv[1], "omp", ompImg);

    /** Free any memory leftover.. gpuImig, cpuImg, and ompImg get their pixels free'd while writing **/
    cudaFree(gpu_orig); cudaFree(gpu_sobel);
    return 0;
}

/**
* Output information about the host (CPU) and divce (GPU)
*/
void printCudaDeviceInformation(int maxAvaialbeCores) {
    cudaDeviceProp cudaDeviceProperties;
    cudaGetDeviceProperties(&cudaDeviceProperties, 0);

    printf("########################################################\n");
    printf("#                 Device Information                   #\n");
    printf("########################################################\n");
    printf("CPU: %d Threads\n", std::thread::hardware_concurrency());
    printf("GPU: %s\n\
     CUDA Version %d.%d\n\
     %zd MB global Memory\n\
     %zd KB shared Memory per Block\n\
     %d CUDA cores\n",
        cudaDeviceProperties.name, cudaDeviceProperties.major, cudaDeviceProperties.minor, cudaDeviceProperties.totalGlobalMem >> 20, cudaDeviceProperties.sharedMemPerBlock >> 10, cudaDeviceProperties.multiProcessorCount);
}

/** 
 * The original image is extended by one pixel up, down, left and right. The newly added columns and rows are filled as follows: 
 * Example of an image with 3x3 pixels which is extended to 5x5 pixels
 *                  A   A   B   C   C
 *  A   B   C       A   A   B   C   C
 *  D   E   F   ->  D   D   E   F   F
 *  G   H   I       G   G   H   I   I
 *                  G   G   H   I   I
 *
 * The original borders are copied to the newly added border. The same is done for the corners
*/
void fillExpandedPicture(const byte* originalImage, byte* expandedImage, const unsigned int width, const unsigned int height) {
    //copy data from original image to the expanded image and fill the new added rows/columns
    imageWidth = width;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            //cases for corners
            if (y == 0 && x == 0) {
                expandedImage[getIndex(x, y)] = originalImage[getIndex(x, y)];
            } else if (y == 0 && x == width - 1) {
                expandedImage[getIndex(x, y)] = originalImage[getIndex(x - 2, y)];
            } else if (y == height - 1 && x == 0) {
                expandedImage[getIndex(x, y)] = originalImage[(width - 2) * (y - 2) + x];
            } else if (y == height - 1 && x == width - 1) {
                expandedImage[getIndex(x, y)] = originalImage[(width - 2) * (y - 2) + (x - 2)];
            
            //cases for edges
            } else if (y == 0) {
                expandedImage[getIndex(x, y)] = originalImage[getIndex(x - 1, y)];
            } else if (y > 0 && x == 0) {
                expandedImage[getIndex(x, y)] = originalImage[(width - 2) * (y - 1) + x];
            } else if (y > 0 && x == width - 1) {
                expandedImage[getIndex(x, y)] = originalImage[(width - 2) * (y - 1) + (x - 2)];
            } else if (y == height - 1 && x > 0) {
                expandedImage[getIndex(x, y)] = originalImage[(width - 2) * (y - 2) + (x - 1)];
            }

            //fill in the normal image
            else {
                expandedImage[getIndex(x, y)] = originalImage[(width - 2) * (y - 1) + (x - 1)];
            }
        }
    }
}

void executeSobelOperator(char* image, int maxAvailableCores) {
    //==========================================================
    // 1. Step: load image
    //==========================================================
    imgData originalImage = loadImage(image);

    //==========================================================
    // 2. Step: allocate create image that is two wider and two 
    //          heigher than the original
    //==========================================================
    imgData expandedImage(new byte[(originalImage.width + 2) * (originalImage.height + 2)], originalImage.width + 2, originalImage.height + 2);

    //not necessary: the "fillExpandedPicture" function writes to every entry in the array. Setting every pixel to 0 before is redundant
    //memset(expandedImage.pixels, 0, (expandedImage.width * expandedImage.height));
    fillExpandedPicture(originalImage.pixels, expandedImage.pixels, expandedImage.width, expandedImage.height);

    //set global image width for index calculation
    //imageWidth = originalImage.width;

    //==========================================================
    // 3. Step: allocate memory for the results
    //==========================================================
    imgData separateStepCpuImgageWithIndexing(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData separateStepCpuImgageWithInlineIndexing(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData separateStepCpuImgageWithoutIndexing(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData separateStepCpuImgageWithOptimzedCalculation(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData combinedStepsCpuImage(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData combinedStepsCpuImageOptimized(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);

    imgData separateStepOmpImgageWithIndexing(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData separateStepOmpImgageWithInlineIndexing(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData separateStepOmpImgageWithoutIndexing(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData separateStepOmpImgageWithOptimzedCalculation(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData combinedStepsOmpImage(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);
    imgData combinedStepsOmpImageOptimized(new byte[originalImage.width * originalImage.height], originalImage.width, originalImage.height);




    //definitions for time measurement
    std::chrono::system_clock::time_point start;
    std::chrono::duration<double> serparatedStepWithIndexingCpuTime;
    std::chrono::duration<double> serparatedStepWithInlineIndexingCpuTime;
    std::chrono::duration<double> serparatedStepWithoutIndexingCpuTime;
    std::chrono::duration<double> serparatedStepWithOptimizedCalculationCpuTime;
    std::chrono::duration<double> combinedStepsCpuTime;
    std::chrono::duration<double> combinedStepsOptimizedCpuTime;

    std::chrono::duration<double> serparatedStepWithIndexingOmpTime;
    std::chrono::duration<double> serparatedStepWithInlineIndexingOmpTime;
    std::chrono::duration<double> serparatedStepWithoutIndexingOmpTime;
    std::chrono::duration<double> serparatedStepWithOptimizedCalculationOmpTime;
    std::chrono::duration<double> combinedStepsOmpTime;
    std::chrono::duration<double> combinedStepsOptimizedOmpTime;

    //==========================================================
    // 5. Step: Executing and meassering 
    //==========================================================

    //Single core sobel function with indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuWithIndexing(expandedImage.pixels, separateStepCpuImgageWithIndexing.pixels, expandedImage.width, expandedImage.height, 1);
    serparatedStepWithIndexingCpuTime = std::chrono::system_clock::now() - start;

    //Single core sobel function with inline indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuWithInlineIndexing(expandedImage.pixels, separateStepCpuImgageWithInlineIndexing.pixels, expandedImage.width, expandedImage.height, 1);
    serparatedStepWithInlineIndexingCpuTime = std::chrono::system_clock::now() - start;

    //Single core soble function without indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuWithoutIndexing(expandedImage.pixels, separateStepCpuImgageWithoutIndexing.pixels, expandedImage.width, expandedImage.height, 1);
    serparatedStepWithoutIndexingCpuTime = std::chrono::system_clock::now() - start;

    //Single core soble function without indexing, seperated steps (3 total steps) and optimized calculations 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuOptimizedCalculation(expandedImage.pixels, separateStepCpuImgageWithOptimzedCalculation.pixels, expandedImage.width, expandedImage.height, 1);
    serparatedStepWithOptimizedCalculationCpuTime = std::chrono::system_clock::now() - start;

    //Single core soble function without indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    combinedStepsSobelCpu(expandedImage.pixels, combinedStepsCpuImage.pixels, expandedImage.width, expandedImage.height, 1);
    combinedStepsCpuTime = std::chrono::system_clock::now() - start;

    //Single core soble function without indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    combinedStepsSobelCpuOptimized(expandedImage.pixels, combinedStepsCpuImageOptimized.pixels, expandedImage.width, expandedImage.height, 1);
    combinedStepsOptimizedCpuTime = std::chrono::system_clock::now() - start;



    //Multi core sobel function with indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuWithIndexing(expandedImage.pixels, separateStepOmpImgageWithIndexing.pixels, expandedImage.width, expandedImage.height, maxAvailableCores);
    serparatedStepWithIndexingOmpTime = std::chrono::system_clock::now() - start;

    //Multi core sobel function with inline indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuWithInlineIndexing(expandedImage.pixels, separateStepOmpImgageWithInlineIndexing.pixels, expandedImage.width, expandedImage.height, maxAvailableCores);
    serparatedStepWithInlineIndexingOmpTime = std::chrono::system_clock::now() - start;

    //Multi core soble function without indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuWithoutIndexing(expandedImage.pixels, separateStepOmpImgageWithoutIndexing.pixels, expandedImage.width, expandedImage.height, maxAvailableCores);
    serparatedStepWithoutIndexingOmpTime = std::chrono::system_clock::now() - start;

    //Multi core soble function without indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separateStepSobelCpuOptimizedCalculation(expandedImage.pixels, separateStepOmpImgageWithOptimzedCalculation.pixels, expandedImage.width, expandedImage.height, maxAvailableCores);
    serparatedStepWithOptimizedCalculationOmpTime = std::chrono::system_clock::now() - start;

    start = std::chrono::system_clock::now();
    combinedStepsSobelCpu(expandedImage.pixels, combinedStepsOmpImage.pixels, expandedImage.width, expandedImage.height, maxAvailableCores);
    combinedStepsOmpTime = std::chrono::system_clock::now() - start;

    //Single core soble function without indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    combinedStepsSobelCpuOptimized(expandedImage.pixels, combinedStepsOmpImageOptimized.pixels, expandedImage.width, expandedImage.height, maxAvailableCores);
    combinedStepsOptimizedOmpTime = std::chrono::system_clock::now() - start;

    /*Multi core soble function without indexing and seperated steps (3 total steps) 
    start = std::chrono::system_clock::now();
    separate_step_sobel_cpu_without_indexing(expandedImage.pixels, omp_combined_step_cpuImgage.pixels, expandedImage.width, expandedImage.height, maxAvailableCores);
    serparatedStepWithoutIndexingOMPTime = std::chrono::system_clock::now() - start;*/




    printf("CPU with Indexing            = %*.1f msec\n", 5, 1000 * serparatedStepWithIndexingCpuTime.count());
    printf("OMP with Indexing            = %*.1f msec\n\n", 5, 1000 * serparatedStepWithIndexingOmpTime.count());

    printf("CPU with inline Indexing     = %*.1f msec\n", 5, 1000 * serparatedStepWithInlineIndexingCpuTime.count());
    printf("OMP with inline Indexing     = %*.1f msec\n\n", 5, 1000 * serparatedStepWithInlineIndexingOmpTime.count());

    printf("CPU without Indexing         = %*.1f msec\n", 5, 1000 * serparatedStepWithoutIndexingCpuTime.count());
    printf("OMP without Indexing         = %*.1f msec\n\n", 5, 1000 * serparatedStepWithoutIndexingOmpTime.count());

    printf("CPU optimized Calc           = %*.1f msec\n", 5, 1000 * serparatedStepWithOptimizedCalculationCpuTime.count());
    printf("OMP optimized Calc           = %*.1f msec\n\n", 5, 1000 * serparatedStepWithOptimizedCalculationOmpTime.count());

    printf("CPU combined Steps           = %*.1f msec\n", 5, 1000 * combinedStepsCpuTime.count());
    printf("OMP combined Steps           = %*.1f msec\n\n", 5, 1000 * combinedStepsOmpTime.count());


    printf("CPU combined Steps Optimized = %*.1f msec\n", 5, 1000 * combinedStepsOptimizedCpuTime.count());
    printf("OMP combined Steps Optimized = %*.1f msec\n\n", 5, 1000 * combinedStepsOptimizedOmpTime.count());

    writeImage(image, "cpu_1", separateStepCpuImgageWithIndexing);
    writeImage(image, "cpu_2", separateStepCpuImgageWithInlineIndexing);
    writeImage(image, "cpu_3", separateStepCpuImgageWithoutIndexing);
    writeImage(image, "cpu_4", separateStepCpuImgageWithOptimzedCalculation);
    writeImage(image, "cpu_5", combinedStepsCpuImage);
    writeImage(image, "cpu_6", combinedStepsOmpImage);
}

/**
* First implementation of the Sobel operator. In this case, dx and dy are each calculated in a separate run. 
* At the end, the result of dx and dy is also calculated. This results in 3 separate runs. 
* For the access to the one dimensional array an extra getIndex function is used, which allows to access the one dimensional array 
* like a two dimensional array. This implementation does not contain any optimizations and will serve as a basis for comparison 
* to all other Sobel operator implementations.
*/
void separateStepSobelCpuWithIndexing(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores) {
    int* dx = new int[(width - 2) * (height - 2)];
    int* dy = new int[(width - 2) * (height - 2)];

    omp_set_num_threads(maxCores);
    imageWidth = width;

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            dx[(width - 2) * (y - 1) + (x - 1)] = (1 * image[getIndex(x - 1, y - 1)]) + (-1 * image[getIndex(x + 1, y - 1)]) +
                (2 * image[getIndex(x - 1, y)]) + (-2 * image[getIndex(x + 1, y)]) +
                (1 * image[getIndex(x - 1, y + 1)]) + (-1 * image[getIndex(x + 1, y + 1)]);
        }
    }

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            dy[(width - 2) * (y - 1) + (x - 1)] = (1 * image[getIndex(x - 1, y - 1)]) + (2 * image[getIndex(x, y - 1)]) + (1 * image[getIndex(x + 1, y - 1)]) +
                (-1 * image[getIndex(x - 1, y + 1)]) + (-2 * image[getIndex(x, y + 1)]) + (-1 * image[getIndex(x + 1, y + 1)]);
        }
    }

    imageWidth = width - 2;
    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            result[getIndex(x - 1, y - 1)] = sqrt((dx[getIndex(x - 1, y - 1)] * dx[getIndex(x - 1, y - 1)]) + (dy[getIndex(x - 1, y - 1)] * dy[getIndex(x - 1, y - 1)]));
        }
    }
}

/**
 * Same implmentation as before, the only optimization is that the indexing function is now a inline function 
 */
void separateStepSobelCpuWithInlineIndexing(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores) {
    int* dx = new int[(width - 2) * (height - 2)];
    int* dy = new int[(width - 2) * (height - 2)];

    omp_set_num_threads(maxCores);
    imageWidth = width;

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            dx[(width - 2) * (y - 1) + (x - 1)] = (1 * image[getIndexInline(x - 1, y - 1)]) + (-1 * image[getIndexInline(x + 1, y - 1)]) +
                (2 * image[getIndexInline(x - 1, y)]) + (-2 * image[getIndexInline(x + 1, y)]) +
                (1 * image[getIndexInline(x - 1, y + 1)]) + (-1 * image[getIndexInline(x + 1, y + 1)]);
        }
    }

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            dy[(width - 2) * (y - 1) + (x - 1)] = (1 * image[getIndexInline(x - 1, y - 1)]) + (2 * image[getIndexInline(x, y - 1)]) + (1 * image[getIndexInline(x + 1, y - 1)]) +
                (-1 * image[getIndexInline(x - 1, y + 1)]) + (-2 * image[getIndexInline(x, y + 1)]) + (-1 * image[getIndexInline(x + 1, y + 1)]);
        }
    }

    imageWidth = width - 2;
    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            result[getIndexInline(x - 1, y - 1)] = sqrt((dx[getIndexInline(x - 1, y - 1)] * dx[getIndexInline(x - 1, y - 1)]) + (dy[getIndexInline(x - 1, y - 1)] * dy[getIndexInline(x - 1, y - 1)]));
        }
    }
}

//Same implementation but the calculation is now moved away from an extra function directly into the code
void separateStepSobelCpuWithoutIndexing(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores) {
    int* dx = new int[(width - 2) * (height - 2)];
    int* dy = new int[(width - 2) * (height - 2)];

    omp_set_num_threads(maxCores);

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            dx[(width - 2) * (y - 1) + (x - 1)] = (1 * image[width * (y - 1) + (x - 1)]) + (-1 * image[width * (y - 1) + (x + 1)]) +
                (2 * image[width * y + (x - 1)]) + (-2 * image[width * y + (x + 1)]) +
                (1 * image[width * (y + 1) + (x - 1)]) + (-1 * image[width * (y + 1) + (x + 1)]);
        }
    }

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            dy[(width - 2) * (y - 1) + (x - 1)] = (image[(y - 1) * width + (x - 1)]) + (2 * image[(y - 1) * width + x]) + (image[(y - 1) * width + (x + 1)]) +
                (-1 * image[(y + 1) * width + (x - 1)]) + (-2 * image[(y + 1) * width + x]) + (-1 * image[(y + 1) * width + (x + 1)]);
        }
    }
    
    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            result[(y - 1) * (width - 2) + (x - 1)] = sqrt((dx[(y - 1) * (width - 2) + (x - 1)] * dx[(y - 1) * (width - 2) + (x - 1)]) + (dy[(y - 1) * (width - 2) + (x - 1)] * dy[(y - 1) * (width - 2) + (x - 1)]));
        }
    }
}

//optimized calculation
void separateStepSobelCpuOptimizedCalculation(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores) {
    int* dx = new int[(width - 2) * (height - 2)];
    int* dy = new int[(width - 2) * (height - 2)];

    omp_set_num_threads(maxCores);

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        int tmpWidth = width * y;
        for (int x = 1; x < width - 1; x++) {
            dx[(width - 2) * (y - 1) + (x - 1)] = (image[tmpWidth - width + (x - 1)]) + (-image[tmpWidth - width + (x + 1)]) +
                (image[tmpWidth + (x - 1)] << 1) + (-(image[tmpWidth + (x + 1)] << 1)) +
                (image[tmpWidth + width + (x - 1)]) + (-image[tmpWidth + width + (x + 1)]);
        }
    }

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        int tmpWidth = width * y;
        for (int x = 1; x < width - 1; x++) {
            dy[(width - 2) * (y - 1) + (x - 1)] = (image[tmpWidth - width + (x - 1)]) + (image[tmpWidth - width + x] << 1) + (image[tmpWidth - width + (x + 1)]) +
                (-image[tmpWidth + width + (x - 1)]) + (-(image[tmpWidth + width + x] << 1)) + (-image[tmpWidth + width + (x + 1)]);
        }
    }

    #pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        int tmpWidth = (width - 2) * (y - 1);
        for (int x = 1; x < width - 1; x++) {
            result[tmpWidth + (x - 1)] = sqrt((dx[tmpWidth + (x - 1)] * dx[tmpWidth + (x - 1)]) + (dy[tmpWidth + (x - 1)] * dy[tmpWidth + (x - 1)]));
        }
    }
}

void combinedStepsSobelCpu(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores) {
    omp_set_num_threads(maxCores);

    #pragma omp parallel for collapse(2)
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int dx = (image[width * (y - 1) + (x - 1)]) + (-image[width * (y - 1) + (x + 1)]) +
                (2 * image[width * y + (x - 1)]) + (-2 * image[width * y + (x + 1)]) +
                (image[width * (y + 1) + (x - 1)]) + (-image[width * (y + 1) + (x + 1)]);

            int dy = (image[(y - 1) * width + (x - 1)]) + (2 * image[(y - 1) * width + x]) + (image[(y - 1) * width + (x + 1)]) +
                (-image[(y + 1) * width + (x - 1)]) + (-2 * image[(y + 1) * width + x]) + (-image[(y + 1) * width + (x + 1)]);

            result[(width - 2) * (y - 1) + (x - 1)] = sqrt((dx * dx) + (dy * dy));
        }
    }
}

void combinedStepsSobelCpuOptimized(const byte* image, byte* result, const unsigned int width, const unsigned int height, int maxCores) {
    omp_set_num_threads(maxCores);

#pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        int tmp = width * y;
        int tmp_m = tmp - width;
        int tmp_p = tmp + width;
        for (int x = 1; x < width - 1; x++) {
            int dx = (image[tmp_m + (x - 1)]) + (-image[tmp_m + (x + 1)]) +
                (2 * image[tmp + (x - 1)]) + (-2 * image[tmp + (x + 1)]) +
                (image[tmp_p + (x - 1)]) + (-image[tmp_p + (x + 1)]);

            int dy = (image[tmp_m + (x - 1)]) + (2 * image[tmp_m + x]) + (image[tmp_m + (x + 1)]) +
                (-image[tmp_p + (x - 1)]) + (-2 * image[tmp_p + x]) + (-image[tmp_p + (x + 1)]);

            result[(width - 2) * (y - 1) + (x - 1)] = sqrt((dx * dx) + (dy * dy));
        }
    }
}

/************************************************************************************************
 * void combined_step_sobel_cpu(const byte*, byte*, uint, uint);
 * - This function runs on just the CPU with nothing running in parallel. The function takes in
 * - an original image and compares the pixels to the left and right and then above and below
 * - to find the rate of change of the two comparisons, then squares, adds, and square roots the
 * - pair to find a 'sobel' value, this value is saved into an array of bytes and then loops to
 * - handle the next pixel. The resulting array of evaluated pixels should be of an image showing
 * - in black and white where edges appear in the original image.
 *
 * Inputs: const byte* orig : the original image being evaluated
 *                byte* cpu : the image being created using the sobel filter
 *               uint width : the width of the image
 *              uint height : the height of the image
 *
 ***********************************************************************************************/
void combined_step_sobel_cpu(const byte* orig, byte* cpu, const unsigned int width, const unsigned int height) {
    /*for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int dx = (-1 * orig[(y - 1) * width + (x - 1)]) + (-2 * orig[y * width + (x - 1)]) + (-1 * orig[(y + 1) * width + (x - 1)]) +
                (orig[(y - 1) * width + (x + 1)]) + (2 * orig[y * width + (x + 1)]) + (orig[(y + 1) * width + (x + 1)]);
            int dy = (orig[(y - 1) * width + (x - 1)]) + (2 * orig[(y - 1) * width + x]) + (orig[(y - 1) * width + (x + 1)]) +
                (-1 * orig[(y + 1) * width + (x - 1)]) + (-2 * orig[(y + 1) * width + x]) + (-1 * orig[(y + 1) * width + (x + 1)]);
            cpu[y * width + x] = sqrt((dx * dx) + (dy * dy));
        }
    }*/

    /*for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int dx = (1 * orig[getIndex(x - 1, y - 1)]) + (-1 * orig[getIndex(x + 1, y - 1)]) +
                (2 * orig[getIndex(x - 1, y)]) + (-2 * orig[getIndex(x + 1, y)]) +
                (1 * orig[getIndex(x - 1, y + 1)]) + (-1 * orig[getIndex(x + 1, y + 1)]);

            int dy = (1 * orig[getIndex(x - 1, y - 1)]) + (2 * orig[getIndex(x, y - 1)]) + (1 * orig[getIndex(x + 1, y - 1)]) +
                (-1 * orig[getIndex(x - 1, y + 1)]) + (-2 * orig[getIndex(x, y + 1)]) + (-1 * orig[getIndex(x + 1, y + 1)]);

            cpu[getIndex(x, y)] = sqrt((dx * dx) + (dy * dy));
        }
    }*/
    //imageWidth* y + x;
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int dx = (1 * orig[imageWidth * (y - 1) + (x - 1)]) + (-1 * orig[imageWidth * (y - 1) + (x + 1)]) +
                (2 * orig[imageWidth * y + (x - 1)]) + (-2 * orig[imageWidth * y + (x + 1)]) +
                (1 * orig[imageWidth * (y + 1) + (x - 1)]) + (-1 * orig[imageWidth * (y + 1) + (x + 1)]);

            int dy = (1 * orig[imageWidth * (y - 1) + (x - 1)]) + (2 * orig[imageWidth * (y - 1) + x]) + (1 * orig[imageWidth * (y - 1) + (x + 1)]) +
                (-1 * orig[imageWidth * (y + 1) + (x - 1)]) + (-2 * orig[imageWidth * (y + 1) + x]) + (-1 * orig[imageWidth * (y + 1) + (x + 1)]);

            cpu[imageWidth * y + x] = sqrt((dx * dx) + (dy * dy));
        }
    }
}


/************************************************************************************************
 * void sobel_omp(const byte*, byte*, uint, uint);
 * - This function runs on the CPU but uses OpenMP to parallelize the for workload. The function
 * - is identical to the sobel_cpu function in what it does, except there is a #pragma call for
 * - the compiler to seperate out the for loop across different cores. Each pixel is able to be
 * - worked on independantly of all other pixels, so there is no worry of one thread messing up
 * - another thread. The resulting array is the same as the cpu function, producing an image in
 * - black and white of where edges appear in the original image.
 *
 * Inputs: const byte* orig : the original image being evaluated
 *                byte* cpu : the image being created using the sobel filter
 *               uint width : the width of the image
 *              uint height : the height of the image
 *
 ***********************************************************************************************/
void sobel_omp(const byte* orig, byte* cpu, const unsigned int width, const unsigned int height) {
#pragma omp parallel for
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int dx = (-1 * orig[(y - 1) * width + (x - 1)]) + (-2 * orig[y * width + (x - 1)]) + (-1 * orig[(y + 1) * width + (x - 1)]) +
                (orig[(y - 1) * width + (x + 1)]) + (2 * orig[y * width + (x + 1)]) + (orig[(y + 1) * width + (x + 1)]);
            int dy = (orig[(y - 1) * width + (x - 1)]) + (2 * orig[(y - 1) * width + x]) + (orig[(y - 1) * width + (x + 1)]) +
                (-1 * orig[(y + 1) * width + (x - 1)]) + (-2 * orig[(y + 1) * width + x]) + (-1 * orig[(y + 1) * width + (x + 1)]);
            cpu[y * width + x] = sqrt((dx * dx) + (dy * dy));
        }
    }
}


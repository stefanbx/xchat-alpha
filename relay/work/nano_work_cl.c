// GPU proof-of-work for Nano blocks, via OpenCL.
//
// WHY. A Nano block needs PoW before it can be broadcast, and that is the single thing standing
// between "tip sent" and "tip settled". The hosted node has no dedicated work source, so it races
// free public RPCs (0.9s..36s, rate-limited, sometimes 403) and falls back to on-box CPU (~1 minute
// on a 2-vCPU box). A multi-leg tip needs several of these back to back, which is why settlement
// used to spin or time out.
//
// Work is a brute-force search for a nonce whose blake2b(nonce || root) clears a threshold — perfectly
// parallel, tiny state, no branching. That is the shape a GPU is built for, and any laptop GPU
// outruns a datacenter CPU core at it by orders of magnitude.
//
// SAFE TO ACCEPT FROM STRANGERS. A work value is trivially VERIFIABLE (one hash) and carries no
// authority: it authorises nothing, spends nothing, and signs nothing. So a relay can compute work for
// other people's blocks and the consumer simply validates the answer before using it — a malicious or
// broken generator can waste its own electricity and nothing else. That is what makes PoW the one job
// in this system safe to hand to an untrusted peer.
//
//   cc -O3 nano_work_cl.c -o nano_work_cl -framework OpenCL          (macOS)
//   cc -O3 nano_work_cl.c -o nano_work_cl -lOpenCL                   (Linux)
//   ./nano_work_cl <root-hex-64> [difficulty-hex-16]   ->  prints the 16-hex work value
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CL_SILENCE_DEPRECATION
#ifdef __APPLE__
#include <OpenCL/opencl.h>
#else
#include <CL/cl.h>
#endif

// Mainnet send/change threshold. Receive blocks use the easier fffffe0000000000.
#define DEFAULT_DIFFICULTY 0xfffffff800000000UL

static const char *KERNEL_SRC =
"#define ROTR64(x,n) (((x) >> (n)) | ((x) << (64 - (n))))\n"
"__constant ulong IV[8] = {\n"
"  0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL, 0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,\n"
"  0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL, 0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL };\n"
"__constant uchar SIGMA[12][16] = {\n"
"  {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},{14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3},\n"
"  {11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4},{7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8},\n"
"  {9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13},{2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9},\n"
"  {12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11},{13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10},\n"
"  {6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5},{10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0},\n"
"  {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},{14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3} };\n"
"#define G(r,i,a,b,c,d) \\\n"
"  a = a + b + m[SIGMA[r][2*i]];   d = ROTR64(d ^ a, 32); \\\n"
"  c = c + d;                      b = ROTR64(b ^ c, 24); \\\n"
"  a = a + b + m[SIGMA[r][2*i+1]]; d = ROTR64(d ^ a, 16); \\\n"
"  c = c + d;                      b = ROTR64(b ^ c, 63);\n"
"#define ROUND(r) \\\n"
"  G(r,0,v[0],v[4],v[ 8],v[12]) G(r,1,v[1],v[5],v[ 9],v[13]) \\\n"
"  G(r,2,v[2],v[6],v[10],v[14]) G(r,3,v[3],v[7],v[11],v[15]) \\\n"
"  G(r,4,v[0],v[5],v[10],v[15]) G(r,5,v[1],v[6],v[11],v[12]) \\\n"
"  G(r,6,v[2],v[7],v[ 8],v[13]) G(r,7,v[3],v[4],v[ 9],v[14])\n"
"\n"
"// blake2b-64bit-digest over the 40-byte message (nonce || root), one compression, no key.\n"
// The root is passed pre-packed into 4 little-endian words. Re-deriving it inside the kernel meant
// every one of millions of threads repeated the same 32 byte-loads and shifts for an identical result,
// which is pure waste next to the 12 blake2b rounds that are the actual job.
"__kernel void nano_work(__global ulong *out, ulong r0, ulong r1, ulong r2, ulong r3,\n"
"                        ulong difficulty, ulong base) {\n"
"  ulong nonce = base + (ulong)get_global_id(0);\n"
"  ulong m[16] = {0};\n"
"  // message = 8-byte nonce (little-endian) followed by the 32-byte root\n"
"  m[0] = nonce; m[1] = r0; m[2] = r1; m[3] = r2; m[4] = r3;\n"
"  ulong v[16];\n"
"  ulong h0 = IV[0] ^ 0x01010008UL;   // depth=1, fanout=1, keylen=0, digest_length=8\n"
"  v[0]=h0; for (int i=1;i<8;i++) v[i]=IV[i];\n"
"  for (int i=0;i<8;i++) v[8+i]=IV[i];\n"
"  v[12] ^= 40UL;                     // t0: bytes compressed\n"
"  v[14] ^= 0xFFFFFFFFFFFFFFFFUL;     // f0: this is the last block\n"
"  ROUND(0) ROUND(1) ROUND(2) ROUND(3) ROUND(4) ROUND(5)\n"
"  ROUND(6) ROUND(7) ROUND(8) ROUND(9) ROUND(10) ROUND(11)\n"
"  ulong digest = h0 ^ v[0] ^ v[8];\n"
"  if (digest >= difficulty) out[0] = nonce;   // any winner will do; races are harmless\n"
"}\n";

static int hex2bin(const char *h, unsigned char *o, size_t n) {
  if (strlen(h) != n * 2) return 0;
  for (size_t i = 0; i < n; i++) {
    unsigned v;
    if (sscanf(h + i * 2, "%2x", &v) != 1) return 0;
    o[i] = (unsigned char)v;
  }
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <root-hex-64> [difficulty-hex]\n", argv[0]); return 2; }
  unsigned char root[32];
  if (!hex2bin(argv[1], root, 32)) { fprintf(stderr, "root must be 64 hex chars\n"); return 2; }
  cl_ulong difficulty = DEFAULT_DIFFICULTY;
  if (argc > 2) difficulty = strtoull(argv[2], NULL, 16);

  cl_platform_id plat; cl_device_id dev;
  cl_int err = clGetPlatformIDs(1, &plat, NULL);
  if (err != CL_SUCCESS) { fprintf(stderr, "no opencl platform\n"); return 3; }
  if (clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, NULL) != CL_SUCCESS) {
    fprintf(stderr, "no opencl gpu\n"); return 3;
  }
  cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
  cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err);
  cl_program prog = clCreateProgramWithSource(ctx, 1, &KERNEL_SRC, NULL, &err);
  if (clBuildProgram(prog, 1, &dev, "", NULL, NULL) != CL_SUCCESS) {
    char log[8192] = {0};
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL);
    fprintf(stderr, "kernel build failed:\n%s\n", log); return 4;
  }
  cl_kernel k = clCreateKernel(prog, "nano_work", &err);

  cl_ulong found = 0;
  cl_mem out = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, sizeof found, &found, &err);
  cl_ulong rw[4];                       // root as 4 little-endian words, packed once here
  for (int i = 0; i < 4; i++) {
    cl_ulong w = 0;
    for (int b = 7; b >= 0; b--) w = (w << 8) | (cl_ulong)root[i * 8 + b];
    rw[i] = w;
  }

  // A batch must be large enough to amortise the launch + clFinish + readback round trip. At the send
  // threshold the search needs ~2^29 hashes on average, so 2^24 per batch means tens of round trips
  // rather than hundreds.
  size_t batch = 1 << 24;

  // The starting nonce MUST be unpredictable. Seeding from rand() unseeded (or from time() alone) makes
  // every run on every machine start at almost the same place: two relays asked for work in the same
  // second would grind through an identical search space, and repeated calls here re-walk ground that
  // has already been shown not to contain a solution. Take it from the OS entropy source.
  cl_ulong base = 0;
  FILE *ur = fopen("/dev/urandom", "rb");
  if (!ur || fread(&base, sizeof base, 1, ur) != 1) base = (cl_ulong)time(NULL) * 6364136223846793005UL;
  if (ur) fclose(ur);
  clSetKernelArg(k, 0, sizeof(cl_mem), &out);
  for (int i = 0; i < 4; i++) clSetKernelArg(k, 1 + i, sizeof(cl_ulong), &rw[i]);
  clSetKernelArg(k, 5, sizeof(cl_ulong), &difficulty);

  // `--bench` measures raw throughput. Timing real solves cannot do this: solve time is exponentially
  // distributed, so a ten-sample mean carries ~30% error and two kernel versions look different when
  // they are not. Here the difficulty is unreachable, so a fixed number of batches always runs to
  // completion and the hash rate falls straight out of the wall clock.
  if (getenv("XC_WORK_BENCH")) {
    cl_ulong impossible = 0xFFFFFFFFFFFFFFFFUL;
    clSetKernelArg(k, 5, sizeof(cl_ulong), &impossible);
    int batches = 24;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < batches; i++) {
      clSetKernelArg(k, 6, sizeof(cl_ulong), &base);
      clEnqueueNDRangeKernel(q, k, 1, NULL, &batch, NULL, 0, NULL, NULL);
      base += batch;
    }
    clFinish(q);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    double hashes = (double)batch * batches;
    fprintf(stderr, "%.0f MH/s (%.0f M hashes in %.2fs)\n", hashes / secs / 1e6, hashes / 1e6, secs);
    return 0;
  }

  for (;;) {
    clSetKernelArg(k, 6, sizeof(cl_ulong), &base);
    if (clEnqueueNDRangeKernel(q, k, 1, NULL, &batch, NULL, 0, NULL, NULL) != CL_SUCCESS) {
      fprintf(stderr, "kernel enqueue failed\n"); return 5;
    }
    clFinish(q);
    clEnqueueReadBuffer(q, out, CL_TRUE, 0, sizeof found, &found, 0, NULL, NULL);
    if (found) { printf("%016llx\n", (unsigned long long)found); return 0; }
    base += batch;
  }
}

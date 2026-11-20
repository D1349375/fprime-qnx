#include <array>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>

#include <mlpack/core/util/version.hpp>
#include <mlpack/methods/ann/ffn.hpp>
#include <mlpack/methods/ann/layer/layer.hpp>

extern "C" void openblas_set_num_threads(int);
extern "C" int openblas_get_num_threads();

int main(int argc, char** argv) {
    static_assert(MLPACK_VERSION_MAJOR == 4 && MLPACK_VERSION_MINOR == 7, "E6 requires mlpack 4.7");
    if (argc != 2) {
        std::cerr << "Usage: ffn-smoke WEIGHTS\n";
        return 2;
    }
    openblas_set_num_threads(1);
    if (openblas_get_num_threads() != 1) {
        std::cerr << "OpenBLAS did not enter single-thread mode\n";
        return 1;
    }

    mlpack::FFN<mlpack::MeanSquaredError> model;
    model.Add<mlpack::Linear>(3);
    model.Add<mlpack::ReLU>();
    model.Add<mlpack::Linear>(1);
    model.Add<mlpack::Sigmoid>();
    model.Reset(2);
    std::ifstream input(argv[1]);
    std::array<double, 13> weights{};
    if (!input || model.Parameters().n_elem != weights.size()) {
        std::cerr << "Could not open fixture or unexpected FFN parameter layout\n";
        return 1;
    }
    for (auto& weight : weights) {
        if (!(input >> weight) || !std::isfinite(weight)) {
            std::cerr << "Invalid model weight\n";
            return 1;
        }
    }
    input >> std::ws;
    if (!input.eof()) {
        std::cerr << "Unexpected data after the model weights\n";
        return 1;
    }
    for (std::size_t i = 0; i < weights.size(); ++i) {
        model.Parameters()[i] = weights[i];
    }

    const arma::mat features{{-1.0, 1.0, 0.25, 0.0}, {-1.0, 0.5, -0.25, 0.75}};
    arma::mat scores;
    model.Predict(features, scores, 1);
    if (scores.n_rows != 1 || scores.n_cols != features.n_cols) {
        std::cerr << "Unexpected FFN output shape\n";
        return 1;
    }
    std::cout << "case,score,label\n" << std::setprecision(17);
    for (std::size_t i = 0; i < scores.n_cols; ++i) {
        const auto score = scores[i];
        if (!std::isfinite(score) || score < 0.0 || score > 1.0) {
            return 1;
        }
        std::cout << i << ',' << score << ',' << (score >= 0.5 ? 1 : 0) << '\n';
    }
}

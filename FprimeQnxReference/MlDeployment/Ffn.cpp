#include "Ffn.hpp"

#include <array>
#include <cmath>
#include <fstream>
#include <locale>
#include <stdexcept>
#include <string>

#include <mlpack/core/util/version.hpp>
#include <mlpack/methods/ann/ffn.hpp>
#include <mlpack/methods/ann/layer/layer.hpp>

#include "BiasFeatures.hpp"

extern "C" void openblas_set_num_threads(int);
extern "C" int openblas_get_num_threads();

namespace M4 {
namespace {

constexpr std::size_t OpsSatFeatureCount = 18;
static_assert(MLPACK_VERSION_MAJOR == 4 && MLPACK_VERSION_MINOR == 7 && MLPACK_VERSION_PATCH == 0,
              "M4 requires the mlpack 4.7.0 weight layout");

double readNumber(std::istream& input) {
    double number;
    if (!(input >> number) || !std::isfinite(number)) {
        throw std::runtime_error("Expected a finite FFN parameter");
    }
    return number;
}

}  // namespace

class Ffn::Model {
  public:
    mlpack::FFN<mlpack::MeanSquaredError> network;
    arma::mat input;
    arma::mat output;
    std::array<double, OpsSatFeatureCount> compress{};
    std::array<double, OpsSatFeatureCount> center{};
    std::array<double, OpsSatFeatureCount> spread{};
    double threshold = 0.0;
};

Ffn::Ffn(const char* path, Features features) : m_model(new Model) {
    openblas_set_num_threads(1);
    if (openblas_get_num_threads() != 1) {
        throw std::runtime_error("OpenBLAS did not enter single-thread mode");
    }

    const bool adcs = features != Features::OpsSatSegment;
    const char* expectedSchema = adcs ?
        (features == Features::AdcsDrift ? "adcs-drift" : "adcs-bias") : "opssat-segment";
    const std::size_t expectedInputs = adcs ? BiasFeatureCount : OpsSatFeatureCount;
    const std::size_t expectedHidden = adcs ? 8 : 16;
    std::ifstream file(path);
    file.imbue(std::locale::classic());
    std::string version, schema;
    std::size_t count, hidden;
    if (!(file >> version >> schema >> count >> hidden) || version != "m4-ffn-v1" ||
        schema != expectedSchema || count != expectedInputs || hidden != expectedHidden) {
        throw std::runtime_error("Could not load the expected FFN feature schema");
    }

    auto& model = *m_model;
    model.threshold = readNumber(file);
    if (model.threshold < 0.0 || model.threshold > 1.0) {
        throw std::runtime_error("FFN threshold must be between 0 and 1");
    }
    for (std::size_t i = 0; i < count; ++i) {
        model.compress[i] = readNumber(file);
        model.center[i] = readNumber(file);
        model.spread[i] = readNumber(file);
        if (model.compress[i] < 0.0 || model.spread[i] <= 0.0) {
            throw std::runtime_error("Invalid FFN preprocessing scale");
        }
    }

    model.network.Add<mlpack::Linear>(hidden);
    model.network.Add<mlpack::ReLU>();
    model.network.Add<mlpack::Linear>(1);
    model.network.Add<mlpack::Sigmoid>();
    model.network.Reset(count);
    model.input.set_size(count, 1);
    for (auto& parameter : model.network.Parameters()) {
        parameter = readNumber(file);
    }
    file >> std::ws;
    if (!file.eof()) {
        throw std::runtime_error("Unexpected data after the FFN weights");
    }
}

Ffn::~Ffn() = default;

std::size_t Ffn::inputCount() const {
    return m_model->input.n_rows;
}

Prediction Ffn::predict(const double* features, std::size_t count) {
    if (count != inputCount()) {
        throw std::runtime_error("Incorrect FFN input size");
    }
    auto& model = *m_model;
    for (std::size_t i = 0; i < count; ++i) {
        double value = features[i];
        if (model.compress[i] != 0.0) {
            value = std::copysign(std::log1p(std::abs(value) / model.compress[i]), value);
        }
        model.input[i] = (value - model.center[i]) / model.spread[i];
        if (!std::isfinite(model.input[i])) {
            throw std::runtime_error("Non-finite FFN input");
        }
    }
    model.network.Predict(model.input, model.output, 1);
    if (model.output.n_elem != 1) {
        throw std::runtime_error("Incorrect FFN output size");
    }
    const double score = model.output[0];
    if (!std::isfinite(score) || score < 0.0 || score > 1.0) {
        throw std::runtime_error("Invalid FFN score");
    }
    return {score, score >= model.threshold};
}

}  // namespace M4

#include <algorithm>
#include <chrono>
#include <cmath>
#include <exception>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <locale>
#include <sstream>
#include <string>
#include <vector>

#include "MlDeployment/Ffn.hpp"

int main(int argc, char** argv) {
    const std::string schema = argc == 4 ? argv[1] : "";
    if (schema != "adcs-bias" && schema != "opssat-segment") {
        std::cerr << "Usage: m4-replay adcs-bias|opssat-segment MODEL INPUT.csv\n";
        return 2;
    }

    try {
        M4::Ffn model(argv[2], schema == "adcs-bias" ? M4::Features::AdcsBias : M4::Features::OpsSatSegment);
        std::ifstream file(argv[3]);
        if (!file) {
            std::cerr << "Could not open " << argv[3] << '\n';
            return 2;
        }
        std::vector<double> features(model.inputCount(), 0.0);
        (void)model.predict(features.data(), features.size());  // Warm-up is outside the measurements.
        std::cout << "case,status,score,label,inference_ns\n" << std::setprecision(17);
        std::string line;
        while (std::getline(file, line)) {
            const auto delimiter = line.find(',');
            const std::string id = line.substr(0, delimiter);
            try {
                if (delimiter == std::string::npos ||
                    std::count(line.begin(), line.end(), ',') != static_cast<std::ptrdiff_t>(features.size())) {
                    throw std::runtime_error("Incorrect CSV width");
                }
                std::string values = line.substr(delimiter + 1);
                std::replace(values.begin(), values.end(), ',', ' ');
                std::istringstream input(values);
                input.imbue(std::locale::classic());
                for (auto& feature : features) {
                    if (!(input >> feature) || !std::isfinite(feature)) {
                        throw std::runtime_error("Invalid feature");
                    }
                }
                input >> std::ws;
                if (!input.eof()) {
                    throw std::runtime_error("Extra feature data");
                }
                const auto start = std::chrono::steady_clock::now();
                const auto prediction = model.predict(features.data(), features.size());
                const auto elapsed = std::chrono::steady_clock::now() - start;
                std::cout << id << ",ok," << prediction.score << ',' << prediction.alert << ','
                          << std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count() << '\n';
            } catch (const std::exception& error) {
                std::cerr << id << ": " << error.what() << '\n';
                std::cout << id << ",failed,,,\n";
            }
        }
        return file.eof() && std::cout ? 0 : 1;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
